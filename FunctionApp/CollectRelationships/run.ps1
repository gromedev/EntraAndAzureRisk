<#
.SYNOPSIS
    Combined collector for relationship data
.DESCRIPTION
    V3.1 Architecture: Single collector for all edge types → edges.jsonl

    Collects:
    Phase 1.  Group memberships (groups → members)
    Phase 1b. Transitive group memberships
    Phase 2.  Directory role members (roles → members)
    Phase 3.  PIM eligible/active role assignments
    Phase 4.  PIM group eligible/active memberships
    Phase 5.  Azure RBAC assignments
    Phase 6.  Application owners
    Phase 7.  Service Principal owners
    Phase 8.  User license assignments
    Phase 9.  OAuth2 permission grants (consents)
    Phase 10. App role assignments
    Phase 11. Group owners
    Phase 12. Device owners
    Phase 13. Conditional Access policy edges (V3.1)
             - caPolicyTargetsPrincipal
             - caPolicyExcludesPrincipal
             - caPolicyTargetsApplication
             - caPolicyExcludesApplication
             - caPolicyUsesLocation
    Phase 14. Role management policy edges (V3.1)
             - rolePolicyAssignment

    All output to single edges.jsonl with edgeType discriminator.
    Runs phases sequentially to manage memory, streams to blob.
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Verbose "Module imported successfully from: $modulePath"
}
catch {
    $errorMsg = "Failed to import EntraDataCollection module: $($_.Exception.Message)"
    Write-Error $errorMsg
    return @{ Success = $false; Error = $errorMsg }
}
#endregion

#region Validate Environment Variables
$requiredEnvVars = @{
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
    'TENANT_ID' = 'Entra ID tenant ID'
}

$missingVars = @()
foreach ($varName in $requiredEnvVars.Keys) {
    if (-not (Get-Item "Env:$varName" -ErrorAction SilentlyContinue)) {
        $missingVars += "$varName ($($requiredEnvVars[$varName]))"
    }
}

if ($missingVars) {
    $errorMsg = "Missing required environment variables:`n" + ($missingVars -join "`n")
    Write-Warning $errorMsg
    return @{ Success = $false; Error = $errorMsg }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting combined relationships collection"

    # V3: Use shared timestamp from orchestrator (critical for unified blob files)
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens (cached)
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        $azureToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{ Success = $false; Error = "Token acquisition failed: $($_.Exception.Message)" }
    }

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }

    # Results tracking
    $stats = @{
        GroupMembershipsDirect = 0
        GroupMembershipsTransitive = 0
        DirectoryRoles = 0
        PimEligible = 0
        PimActive = 0
        PimGroupEligible = 0
        PimGroupActive = 0
        AzureRbac = 0
        AppOwners = 0
        SpOwners = 0
        Licenses = 0
        OAuth2PermissionGrants = 0
        AppRoleAssignments = 0
        GroupOwners = 0
        DeviceOwners = 0
        CaPolicyEdges = 0
        RolePolicyEdges = 0
    }

    # Performance timer to measure batch optimization impact
    $perfTimer = New-PerformanceTimer

    # Track direct memberships for transitive comparison
    $directMembershipKeys = [System.Collections.Generic.HashSet[string]]::new()
    # Track group nesting (which groups contain which groups)
    $groupNesting = @{}

    # Initialize append blob (V3: unified edges.jsonl)
    $edgesBlobName = "$timestamp/$timestamp-edges.jsonl"
    Write-Verbose "Initializing append blob: $edgesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $edgesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
    }

    # Reusable buffer
    $jsonL = New-Object System.Text.StringBuilder(2097152)
    $writeThreshold = 2000000  # 2MB before flush

    # Splatting params for Write-BlobBuffer (consolidates Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams pattern)
    $flushParams = @{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        BlobName = $edgesBlobName
        AccessToken = $storageToken
        MaxRetries = 3
        BaseRetryDelaySeconds = 2
    }

    #region Phase 1: Direct Group Memberships
    Write-Verbose "=== Phase 1: Direct Group Memberships ==="

    # Get all groups
    $groupSelectFields = "id,displayName,securityEnabled,mailEnabled,groupTypes,isAssignableToRole,visibility"
    $groupsNextLink = "https://graph.microsoft.com/beta/groups?`$select=$groupSelectFields&`$top=$batchSize"

    $groups = [System.Collections.Generic.List[object]]::new()
    while ($groupsNextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $groupsNextLink -AccessToken $graphToken
            $groups.AddRange($response.value)
            $groupsNextLink = $response.'@odata.nextLink'
        }
        catch { Write-Warning "Failed to retrieve groups: $_"; break }
    }

    # Build group lookup by ID for inheritance path resolution
    $groupLookup = @{}
    foreach ($g in $groups) { $groupLookup[$g.id] = $g }

    Write-Verbose "Found $($groups.Count) groups to process for memberships"

    foreach ($group in $groups) {
        try {
            $membersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$select=id,displayName,userPrincipalName,accountEnabled,userType,mail"
            $membersNextLink = $membersUri

            while ($membersNextLink) {
                try {
                    $membersResponse = Invoke-GraphWithRetry -Uri $membersNextLink -AccessToken $graphToken
                    $membersNextLink = $membersResponse.'@odata.nextLink'

                    foreach ($member in $membersResponse.value) {
                        $odataType = $member.'@odata.type'
                        $memberType = switch ($odataType) {
                            '#microsoft.graph.user' { 'user' }
                            '#microsoft.graph.group' { 'group' }
                            '#microsoft.graph.servicePrincipal' { 'servicePrincipal' }
                            '#microsoft.graph.device' { 'device' }
                            default { 'unknown' }
                        }

                        # Track for transitive comparison
                        $membershipKey = "$($member.id)_$($group.id)"
                        [void]$directMembershipKeys.Add($membershipKey)

                        # Track group nesting (which groups contain other groups)
                        if ($memberType -eq 'group') {
                            if (-not $groupNesting.ContainsKey($member.id)) {
                                $groupNesting[$member.id] = [System.Collections.Generic.List[string]]::new()
                            }
                            $groupNesting[$member.id].Add($group.id)
                        }

                        $relationship = @{
                            id = "$($member.id)_$($group.id)_groupMember"
                            objectId = "$($member.id)_$($group.id)_groupMember"
                            edgeType = "groupMember"
                            sourceId = $member.id
                            sourceType = $memberType
                            sourceDisplayName = $member.displayName ?? ""
                            targetId = $group.id
                            targetType = "group"
                            targetDisplayName = $group.displayName ?? ""
                            sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName ?? $null } else { $null }
                            sourceAccountEnabled = if ($null -ne $member.accountEnabled) { $member.accountEnabled } else { $null }
                            sourceUserType = if ($memberType -eq 'user') { $member.userType ?? $null } else { $null }
                            targetSecurityEnabled = if ($null -ne $group.securityEnabled) { $group.securityEnabled } else { $null }
                            targetMailEnabled = if ($null -ne $group.mailEnabled) { $group.mailEnabled } else { $null }
                            targetVisibility = $group.visibility ?? $null
                            targetIsAssignableToRole = if ($null -ne $group.isAssignableToRole) { $group.isAssignableToRole } else { $null }
                            membershipType = "Direct"
                            inheritancePath = @()  # Empty for direct memberships
                            inheritanceDepth = 0
                            collectionTimestamp = $timestampFormatted
                        }

                        [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress -Depth 10))
                        $stats.GroupMembershipsDirect++
                    }
                }
                catch { Write-Warning "Failed to get members for group $($group.displayName): $_"; break }
            }
        }
        catch { Write-Warning "Error processing group $($group.displayName): $_" }

        # Periodic flush
        if ($jsonL.Length -ge ($writeThreshold * 300)) {
            Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
            Write-Verbose "Flushed group memberships buffer ($($stats.GroupMembershipsDirect) direct total)"
        }
    }
    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Direct group memberships complete: $($stats.GroupMembershipsDirect)"
    #endregion

    #region Phase 1b: Transitive Group Memberships
    Write-Verbose "=== Phase 1b: Transitive Group Memberships ==="

    # Helper function to find inheritance path using BFS
    function Get-InheritancePath {
        param(
            [string]$MemberId,
            [string]$TargetGroupId,
            [hashtable]$GroupNesting
        )

        # Find which groups this member belongs to directly
        foreach ($groupId in $GroupNesting.Keys) {
            if ($GroupNesting[$groupId] -contains $TargetGroupId) {
                # This group is directly in target group
                if ($directMembershipKeys.Contains("$MemberId`_$groupId")) {
                    # Member is directly in this intermediate group
                    return @($groupId)
                }
            }
        }

        # For deeper nesting, we'd need recursive lookup
        # For now, return empty path if direct intermediate not found
        return @()
    }

    # Process all groups for transitive memberships
    $groupsToProcess = $groups

    Write-Verbose "Processing $($groupsToProcess.Count) groups for transitive memberships"

    foreach ($group in $groupsToProcess) {
        try {
            # Get transitive members
            $transitiveMembersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/transitiveMembers?`$select=id,displayName,userPrincipalName,accountEnabled,userType"
            $transitiveMembersNextLink = $transitiveMembersUri

            while ($transitiveMembersNextLink) {
                try {
                    $transitiveResponse = Invoke-GraphWithRetry -Uri $transitiveMembersNextLink -AccessToken $graphToken
                    $transitiveMembersNextLink = $transitiveResponse.'@odata.nextLink'

                    foreach ($member in $transitiveResponse.value) {
                        $membershipKey = "$($member.id)_$($group.id)"

                        # Skip if this is a direct membership (already recorded)
                        if ($directMembershipKeys.Contains($membershipKey)) {
                            continue
                        }

                        $odataType = $member.'@odata.type'
                        $memberType = switch ($odataType) {
                            '#microsoft.graph.user' { 'user' }
                            '#microsoft.graph.group' { 'group' }
                            '#microsoft.graph.servicePrincipal' { 'servicePrincipal' }
                            '#microsoft.graph.device' { 'device' }
                            default { 'unknown' }
                        }

                        # Find the intermediate groups this member belongs to that are nested in target group
                        $inheritancePath = @()
                        foreach ($directGroupId in $groupNesting.Keys) {
                            # Check if member is directly in this group AND this group is in target group (directly or transitively)
                            if ($directMembershipKeys.Contains("$($member.id)_$directGroupId")) {
                                if ($groupNesting[$directGroupId] -contains $group.id) {
                                    # Found: member → directGroupId → targetGroup
                                    $inheritancePath += $directGroupId
                                }
                            }
                        }

                        # Calculate depth based on inheritance path
                        $inheritanceDepth = if ($inheritancePath.Count -gt 0) { $inheritancePath.Count } else { 1 }

                        $relationship = @{
                            id = "$($member.id)_$($group.id)_groupMemberTransitive"
                            objectId = "$($member.id)_$($group.id)_groupMemberTransitive"
                            edgeType = "groupMemberTransitive"
                            sourceId = $member.id
                            sourceType = $memberType
                            sourceDisplayName = $member.displayName ?? ""
                            targetId = $group.id
                            targetType = "group"
                            targetDisplayName = $group.displayName ?? ""
                            sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName ?? $null } else { $null }
                            sourceAccountEnabled = if ($null -ne $member.accountEnabled) { $member.accountEnabled } else { $null }
                            sourceUserType = if ($memberType -eq 'user') { $member.userType ?? $null } else { $null }
                            targetSecurityEnabled = if ($null -ne $group.securityEnabled) { $group.securityEnabled } else { $null }
                            targetMailEnabled = if ($null -ne $group.mailEnabled) { $group.mailEnabled } else { $null }
                            targetVisibility = $group.visibility ?? $null
                            targetIsAssignableToRole = if ($null -ne $group.isAssignableToRole) { $group.isAssignableToRole } else { $null }
                            membershipType = "Transitive"
                            inheritancePath = $inheritancePath
                            inheritanceDepth = $inheritanceDepth
                            collectionTimestamp = $timestampFormatted
                        }

                        [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress -Depth 10))
                        $stats.GroupMembershipsTransitive++
                    }
                }
                catch { Write-Warning "Failed to get transitive members for group $($group.displayName): $_"; break }
            }
        }
        catch { Write-Warning "Error processing transitive members for group $($group.displayName): $_" }

        # Periodic flush
        if ($jsonL.Length -ge ($writeThreshold * 300)) {
            Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
            Write-Verbose "Flushed transitive memberships buffer ($($stats.GroupMembershipsTransitive) total)"
        }
    }
    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Transitive group memberships complete: $($stats.GroupMembershipsTransitive)"
    #endregion

    #region Phase 2: Directory Role Members
    Write-Verbose "=== Phase 2: Directory Role Members ==="

    $privilegedRoleTemplates = @(
        '62e90394-69f5-4237-9190-012177145e10',  # Global Administrator
        'e8611ab8-c189-46e8-94e1-60213ab1f814',  # Privileged Role Administrator
        '194ae4cb-b126-40b2-bd5b-6091b380977d',  # Security Administrator
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3',  # Application Administrator
        '158c047a-c907-4556-b7ef-446551a6b5f7',  # Cloud Application Administrator
        '966707d0-3269-4727-9be2-8c3a10f19b9d',  # Password Administrator
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13',  # Privileged Authentication Administrator
        '29232cdf-9323-42fd-ade2-1d097af3e4de',  # Exchange Administrator
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c',  # SharePoint Administrator
        'fe930be7-5e62-47db-91af-98c3a49a38b1'   # User Administrator
    )

    # V3: Use unified roleManagement API instead of legacy directoryRoles
    # This includes both built-in and custom roles, and supports scoped assignments
    # Note: Graph API only allows expanding one property at a time for roleAssignments
    $selectFields = "id,principalId,roleDefinitionId,directoryScopeId"
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$select=$selectFields&`$expand=roleDefinition&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $nextLink = $response.'@odata.nextLink'

            foreach ($assignment in $response.value) {
                $principalId = $assignment.principalId ?? ""
                $roleDefId = $assignment.roleDefinitionId ?? ""
                $roleTemplateId = $assignment.roleDefinition.templateId ?? ""
                $isBuiltIn = $assignment.roleDefinition.isBuiltIn ?? $true
                $isPrivileged = $privilegedRoleTemplates -contains $roleTemplateId
                $directoryScopeId = $assignment.directoryScopeId ?? "/"

                $relationship = @{
                    id = "${principalId}_${roleDefId}_directoryRole"
                    objectId = "${principalId}_${roleDefId}_directoryRole"
                    edgeType = "directoryRole"
                    sourceId = $principalId
                    sourceType = ""  # Enriched from principals container during analysis
                    sourceDisplayName = ""  # Enriched from principals container during analysis
                    targetId = $roleDefId
                    targetType = "directoryRole"
                    targetDisplayName = $assignment.roleDefinition.displayName ?? ""
                    targetRoleTemplateId = $roleTemplateId
                    targetIsPrivileged = $isPrivileged
                    targetIsBuiltIn = $isBuiltIn
                    directoryScopeId = $directoryScopeId
                    isScopedAssignment = ($directoryScopeId -ne "/")
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.DirectoryRoles++
            }
        }
        catch { Write-Warning "Failed to retrieve role assignments batch: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Directory roles complete: $($stats.DirectoryRoles)"
    #endregion

    #region Phase 3: PIM Role Assignments
    Write-Verbose "=== Phase 3: PIM Role Assignments ==="

    # Eligible roles
    # Note: Graph API only allows expanding one property at a time for roleEligibilitySchedules
    $selectFields = "id,principalId,roleDefinitionId,memberType,status,scheduleInfo,createdDateTime,modifiedDateTime"
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?`$select=$selectFields&`$expand=roleDefinition&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            foreach ($assignment in $response.value) {
                $principalId = $assignment.principalId ?? ""
                $roleDefId = $assignment.roleDefinitionId ?? ""

                $relationship = @{
                    id = "${principalId}_${roleDefId}_pimEligible"
                    objectId = "${principalId}_${roleDefId}_pimEligible"
                    edgeType = "pimEligible"
                    assignmentType = "eligible"
                    sourceId = $principalId
                    sourceType = ""  # Enriched from principals container during analysis
                    sourceDisplayName = ""  # Enriched from principals container during analysis
                    targetId = $roleDefId
                    targetType = "directoryRole"
                    targetDisplayName = $assignment.roleDefinition.displayName ?? ""
                    targetRoleTemplateId = $assignment.roleDefinition.templateId ?? ""
                    targetIsPrivileged = $true
                    memberType = $assignment.memberType ?? ""
                    status = $assignment.status ?? ""
                    scheduleInfo = $assignment.scheduleInfo ?? @{}
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.PimEligible++
            }
            $nextLink = $response.'@odata.nextLink'
        }
        catch { Write-Warning "Eligible roles batch error: $_"; break }
    }

    # Active roles
    # Note: Graph API only allows expanding one property at a time for roleAssignmentSchedules
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentSchedules?`$select=$selectFields&`$expand=roleDefinition&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            foreach ($assignment in $response.value) {
                $principalId = $assignment.principalId ?? ""
                $roleDefId = $assignment.roleDefinitionId ?? ""

                $relationship = @{
                    id = "${principalId}_${roleDefId}_pimActive"
                    objectId = "${principalId}_${roleDefId}_pimActive"
                    edgeType = "pimActive"
                    assignmentType = "active"
                    sourceId = $principalId
                    sourceType = ""  # Enriched from principals container during analysis
                    sourceDisplayName = ""  # Enriched from principals container during analysis
                    targetId = $roleDefId
                    targetType = "directoryRole"
                    targetDisplayName = $assignment.roleDefinition.displayName ?? ""
                    targetRoleTemplateId = $assignment.roleDefinition.templateId ?? ""
                    targetIsPrivileged = $true
                    memberType = $assignment.memberType ?? ""
                    status = $assignment.status ?? ""
                    scheduleInfo = $assignment.scheduleInfo ?? @{}
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.PimActive++
            }
            $nextLink = $response.'@odata.nextLink'
        }
        catch { Write-Warning "Active roles batch error: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "PIM roles complete: $($stats.PimEligible) eligible, $($stats.PimActive) active"
    #endregion

    #region Phase 3b: PIM Role Requests (for justification - requires RoleManagement.Read.Directory)
    Write-Verbose "=== Phase 3b: PIM Role Requests (justification) ==="

    # Collect recent role assignment requests to capture justification
    # This provides audit trail of who activated what role with what reason
    $stats.PimRequests = 0

    try {
        $requestsLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests?`$filter=status eq 'Provisioned' or status eq 'PendingApproval'&`$select=id,principalId,roleDefinitionId,action,status,justification,createdDateTime,scheduleInfo,targetScheduleId,createdBy&`$expand=roleDefinition,principal&`$top=$batchSize"

        while ($requestsLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $requestsLink -AccessToken $graphToken
                foreach ($request in $response.value) {
                    $principalId = $request.principalId ?? ""
                    $roleDefId = $request.roleDefinitionId ?? ""

                    $relationship = @{
                        id = "pimRequest_$($request.id)"
                        objectId = "pimRequest_$($request.id)"
                        edgeType = "pimRequest"
                        sourceId = $principalId
                        sourceType = $request.principal.'@odata.type' -replace '#microsoft.graph.', '' ?? ""
                        sourceDisplayName = $request.principal.displayName ?? ""
                        targetId = $roleDefId
                        targetType = "directoryRole"
                        targetDisplayName = $request.roleDefinition.displayName ?? ""
                        targetRoleTemplateId = $request.roleDefinition.templateId ?? ""
                        # PIM Request specific fields
                        action = $request.action ?? ""
                        status = $request.status ?? ""
                        justification = $request.justification ?? ""
                        createdDateTime = $request.createdDateTime ?? $null
                        scheduleInfo = $request.scheduleInfo ?? @{}
                        createdBy = @{
                            id = $request.createdBy.user.id ?? $null
                            displayName = $request.createdBy.user.displayName ?? $null
                        }
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.PimRequests++
                }
                $requestsLink = $response.'@odata.nextLink'
            }
            catch {
                if ($_.Exception.Message -match '403|Forbidden|permission|PermissionScopeNotGranted') {
                    Write-Warning "PIM role requests requires RoleManagement.Read.Directory permission - skipping justification collection"
                } else {
                    Write-Warning "PIM role requests batch error: $_"
                }
                break
            }
        }

        if ($stats.PimRequests -gt 0) {
            Write-Verbose "PIM role requests complete: $($stats.PimRequests) requests with justification"
        }
    }
    catch {
        Write-Warning "PIM role requests collection failed: $_"
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    #endregion

    #region Phase 4: PIM Group Memberships
    Write-Verbose "=== Phase 4: PIM Group Memberships ==="

    # Get role-assignable groups
    $roleAssignableGroups = [System.Collections.Generic.List[object]]::new()
    $groupsLink = "https://graph.microsoft.com/v1.0/groups?`$filter=isAssignableToRole eq true&`$select=id,displayName&`$top=999"
    while ($groupsLink) {
        try {
            $groupsResponse = Invoke-GraphWithRetry -Uri $groupsLink -AccessToken $graphToken
            $roleAssignableGroups.AddRange($groupsResponse.value)
            $groupsLink = $groupsResponse.'@odata.nextLink'
        }
        catch { Write-Warning "Failed to get role-assignable groups: $_"; break }
    }

    Write-Verbose "Found $($roleAssignableGroups.Count) role-assignable groups for PIM"

    $selectFields = "id,principalId,groupId,accessId,memberType,status,scheduleInfo,createdDateTime"

    foreach ($group in $roleAssignableGroups) {
        # Eligible memberships
        $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '$($group.id)'&`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($membership in $response.value) {
                    $principalId = $membership.principalId ?? ""
                    $grpId = $membership.groupId ?? ""
                    $accessId = $membership.accessId ?? ""

                    $relationship = @{
                        id = "${principalId}_${grpId}_${accessId}_pimGroupEligible"
                        objectId = "${principalId}_${grpId}_${accessId}_pimGroupEligible"
                        edgeType = "pimGroupEligible"
                        assignmentType = "eligible"
                        sourceId = $principalId
                        sourceType = ($membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? "")
                        sourceDisplayName = $membership.principal.displayName ?? ""
                        targetId = $grpId
                        targetType = "group"
                        targetDisplayName = $membership.group.displayName ?? ""
                        targetIsAssignableToRole = $true
                        accessId = $accessId
                        memberType = $membership.memberType ?? ""
                        status = $membership.status ?? ""
                        scheduleInfo = $membership.scheduleInfo ?? @{}
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.PimGroupEligible++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Eligible groups batch error for group $($group.id): $_"; break }
        }

        # Active memberships
        $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentSchedules?`$filter=groupId eq '$($group.id)'&`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($membership in $response.value) {
                    $principalId = $membership.principalId ?? ""
                    $grpId = $membership.groupId ?? ""
                    $accessId = $membership.accessId ?? ""

                    $relationship = @{
                        id = "${principalId}_${grpId}_${accessId}_pimGroupActive"
                        objectId = "${principalId}_${grpId}_${accessId}_pimGroupActive"
                        edgeType = "pimGroupActive"
                        assignmentType = "active"
                        sourceId = $principalId
                        sourceType = ($membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? "")
                        sourceDisplayName = $membership.principal.displayName ?? ""
                        targetId = $grpId
                        targetType = "group"
                        targetDisplayName = $membership.group.displayName ?? ""
                        targetIsAssignableToRole = $true
                        accessId = $accessId
                        memberType = $membership.memberType ?? ""
                        status = $membership.status ?? ""
                        scheduleInfo = $membership.scheduleInfo ?? @{}
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.PimGroupActive++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Active groups batch error for group $($group.id): $_"; break }
        }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "PIM groups complete: $($stats.PimGroupEligible) eligible, $($stats.PimGroupActive) active"
    #endregion

    #region Phase 5: Azure RBAC Assignments
    Write-Verbose "=== Phase 5: Azure RBAC Assignments ==="

    # Discover subscriptions
    $subscriptions = Get-AzureManagementPagedResult `
        -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" `
        -AccessToken $azureToken

    Write-Verbose "Found $($subscriptions.Count) Azure subscriptions"

    # Build Azure Role Definition lookup (GUID -> human-friendly name)
    # This resolves targetRoleDefinitionName from GUIDs to names like "Owner", "Contributor", etc.
    $azureRoleLookup = @{}
    if ($subscriptions.Count -gt 0) {
        try {
            $firstSub = $subscriptions[0]
            $roleDefsUri = "https://management.azure.com/subscriptions/$($firstSub.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
            $roleHeaders = @{ 'Authorization' = "Bearer $azureToken"; 'Content-Type' = 'application/json' }
            $roleDefsResponse = Invoke-RestMethod -Uri $roleDefsUri -Method GET -Headers $roleHeaders -ErrorAction Stop
            foreach ($roleDef in $roleDefsResponse.value) {
                # Map role GUID to display name (e.g., "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" -> "Owner")
                $azureRoleLookup[$roleDef.name] = $roleDef.properties.roleName ?? $roleDef.name
            }
            Write-Verbose "Built Azure role lookup: $($azureRoleLookup.Count) role definitions"
        }
        catch {
            Write-Warning "Failed to build Azure role lookup: $_ - role names will show as GUIDs"
        }
    }

    foreach ($sub in $subscriptions) {
        try {
            $uri = "https://management.azure.com$($sub.id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
            $headers = @{
                'Authorization' = "Bearer $azureToken"
                'Content-Type' = 'application/json'
            }

            $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($assignment in $response.value) {
                $scope = $assignment.properties.scope
                $scopeType = "unknown"
                $resourceGroup = $null

                if ($scope -match '/subscriptions/([^/]+)$') {
                    $scopeType = "subscription"
                }
                elseif ($scope -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)$') {
                    $scopeType = "resourceGroup"
                    $resourceGroup = $matches[2]
                }
                elseif ($scope -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/') {
                    $scopeType = "resource"
                    $resourceGroup = $matches[2]
                }

                $principalId = $assignment.properties.principalId ?? ""
                $roleDefId = $assignment.properties.roleDefinitionId ?? ""
                # Extract GUID from full role definition ID path
                $roleGuid = ($roleDefId -split '/')[-1]
                # Look up human-friendly name, fall back to GUID if not found
                $roleDisplayName = if ($azureRoleLookup.ContainsKey($roleGuid)) {
                    $azureRoleLookup[$roleGuid]
                } else {
                    $roleGuid
                }

                $relationship = @{
                    id = "${principalId}_${scope}_azureRbac"
                    objectId = "${principalId}_${scope}_azureRbac"
                    edgeType = "azureRbac"
                    sourceId = $principalId
                    sourceType = $assignment.properties.principalType ?? ""
                    sourceDisplayName = ""  # Enriched from principals container in Dashboard
                    targetId = $roleDefId
                    targetType = "azureRole"
                    targetRoleDefinitionId = $roleDefId
                    targetRoleDefinitionName = $roleDisplayName
                    subscriptionId = $sub.subscriptionId
                    subscriptionName = $sub.displayName ?? ""
                    scope = $scope
                    scopeType = $scopeType
                    scopeDisplayName = $sub.displayName ?? ""
                    resourceGroup = $resourceGroup
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.AzureRbac++
            }
        }
        catch { Write-Warning "Failed to collect RBAC for subscription $($sub.subscriptionId): $_" }

        # Periodic flush
        if ($jsonL.Length -ge ($writeThreshold * 300)) {
            Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
        }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Azure RBAC complete: $($stats.AzureRbac)"
    #endregion

    #region Phase 6: Application Owners (BATCHED)
    Write-Verbose "=== Phase 6: Application Owners (using Graph $batch API) ==="
    $perfTimer.Start("Phase6_AppOwners")

    # Get all applications
    $appSelectFields = "id,displayName,appId,signInAudience,publisherDomain"
    $appsNextLink = "https://graph.microsoft.com/v1.0/applications?`$select=$appSelectFields&`$top=$batchSize"

    while ($appsNextLink) {
        try {
            $appsResponse = Invoke-GraphWithRetry -Uri $appsNextLink -AccessToken $graphToken
            $appsNextLink = $appsResponse.'@odata.nextLink'

            # Build batch requests for all apps in this page
            $batchRequests = @($appsResponse.value | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/applications/$($_.id)/owners?`$select=id,displayName,userPrincipalName,mail"
                }
            })

            # Execute batch request
            $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

            # Process results
            foreach ($app in $appsResponse.value) {
                $ownersResponse = $batchResponses[$app.id]

                # Skip if batch request failed for this app
                if ($null -eq $ownersResponse) {
                    Write-Warning "Batch request failed for app $($app.displayName)"
                    continue
                }

                foreach ($owner in $ownersResponse.value) {
                    $ownerType = ($owner.'@odata.type' -replace '#microsoft.graph.', '')

                    $relationship = @{
                        id = "$($owner.id)_$($app.id)_appOwner"
                        objectId = "$($owner.id)_$($app.id)_appOwner"
                        edgeType = "appOwner"
                        sourceId = $owner.id
                        sourceType = $ownerType
                        sourceDisplayName = $owner.displayName ?? ""
                        sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName ?? $null } else { $null }
                        targetId = $app.id
                        targetType = "application"
                        targetDisplayName = $app.displayName ?? ""
                        targetAppId = $app.appId ?? ""
                        targetSignInAudience = $app.signInAudience ?? ""
                        targetPublisherDomain = $app.publisherDomain ?? ""
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.AppOwners++
                }
            }

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed app owners buffer ($($stats.AppOwners) total)"
            }
        }
        catch { Write-Warning "Failed to retrieve applications batch: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Application owners complete: $($stats.AppOwners)"
    $perfTimer.Stop("Phase6_AppOwners")
    #endregion

    #region Phase 7: Service Principal Owners (BATCHED)
    Write-Verbose "=== Phase 7: Service Principal Owners (using Graph $batch API) ==="
    $perfTimer.Start("Phase7_SpOwners")

    # Get all service principals
    $spSelectFields = "id,displayName,appId,appDisplayName,servicePrincipalType,accountEnabled"
    $spsNextLink = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=$spSelectFields&`$top=$batchSize"

    while ($spsNextLink) {
        try {
            $spsResponse = Invoke-GraphWithRetry -Uri $spsNextLink -AccessToken $graphToken
            $spsNextLink = $spsResponse.'@odata.nextLink'

            # Build batch requests for all SPs in this page
            $batchRequests = @($spsResponse.value | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/servicePrincipals/$($_.id)/owners?`$select=id,displayName,userPrincipalName,mail"
                }
            })

            # Execute batch request
            $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

            # Process results
            foreach ($sp in $spsResponse.value) {
                $ownersResponse = $batchResponses[$sp.id]

                # Skip if batch request failed for this SP
                if ($null -eq $ownersResponse) {
                    Write-Warning "Batch request failed for SP $($sp.displayName)"
                    continue
                }

                foreach ($owner in $ownersResponse.value) {
                    $ownerType = ($owner.'@odata.type' -replace '#microsoft.graph.', '')

                    $relationship = @{
                        id = "$($owner.id)_$($sp.id)_spOwner"
                        objectId = "$($owner.id)_$($sp.id)_spOwner"
                        edgeType = "spOwner"
                        sourceId = $owner.id
                        sourceType = $ownerType
                        sourceDisplayName = $owner.displayName ?? ""
                        sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName ?? $null } else { $null }
                        targetId = $sp.id
                        targetType = "servicePrincipal"
                        targetDisplayName = $sp.displayName ?? ""
                        targetAppId = $sp.appId ?? ""
                        targetAppDisplayName = $sp.appDisplayName ?? ""
                        targetServicePrincipalType = $sp.servicePrincipalType ?? ""
                        targetAccountEnabled = if ($null -ne $sp.accountEnabled) { $sp.accountEnabled } else { $null }
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.SpOwners++
                }
            }

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed SP owners buffer ($($stats.SpOwners) total)"
            }
        }
        catch { Write-Warning "Failed to retrieve service principals batch: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Service principal owners complete: $($stats.SpOwners)"
    $perfTimer.Stop("Phase7_SpOwners")
    #endregion

    #region Phase 8: User License Assignments (BATCHED)
    Write-Verbose "=== Phase 8: User License Assignments (using Graph $batch API) ==="
    $perfTimer.Start("Phase8_UserLicenses")

    # First, get the subscribed SKUs for name lookup
    $skuLookup = @{}
    try {
        $skusResponse = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -AccessToken $graphToken
        foreach ($sku in $skusResponse.value) {
            $skuLookup[$sku.skuId] = @{
                SkuPartNumber = $sku.skuPartNumber
                SkuDisplayName = $sku.skuPartNumber  # Graph doesn't provide friendly names, use part number
            }
        }
        Write-Verbose "Loaded $($skuLookup.Count) license SKUs"
    }
    catch { Write-Warning "Failed to load subscribed SKUs: $_" }

    # Build a group lookup for resolving inherited license group names
    $groupDisplayNameLookup = @{}
    foreach ($g in $groups) {
        $groupDisplayNameLookup[$g.id] = $g.displayName
    }

    # Get all users (we need their license details)
    $userSelectFields = "id,displayName,userPrincipalName,accountEnabled,userType"
    $usersNextLink = "https://graph.microsoft.com/v1.0/users?`$select=$userSelectFields&`$top=$batchSize"

    while ($usersNextLink) {
        try {
            $usersResponse = Invoke-GraphWithRetry -Uri $usersNextLink -AccessToken $graphToken
            $usersNextLink = $usersResponse.'@odata.nextLink'

            # Build batch requests for all users in this page
            $batchRequests = @($usersResponse.value | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/users/$($_.id)/licenseDetails"
                }
            })

            # Execute batch request (up to 20 at a time, handled internally)
            $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

            # Process results
            foreach ($user in $usersResponse.value) {
                $licenseResponse = $batchResponses[$user.id]

                # Skip if batch request failed for this user
                if ($null -eq $licenseResponse) {
                    Write-Warning "Batch request failed for user $($user.userPrincipalName)"
                    continue
                }

                foreach ($license in $licenseResponse.value) {
                    $skuId = $license.skuId ?? ""
                    $skuInfo = $skuLookup[$skuId]
                    $skuPartNumber = if ($skuInfo) { $skuInfo.SkuPartNumber } else { $skuId }

                    # Determine assignment source (direct vs inherited)
                    # If assignedByGroup is empty, it's direct; otherwise inherited
                    $assignmentSource = "direct"
                    $inheritedFromGroupId = $null
                    $inheritedFromGroupName = $null

                    # Check servicePlans for assignment info if available
                    # Note: Graph API v1.0 licenseDetails doesn't expose assignedByGroup directly
                    # We need to use /users/{id}/licenseAssignmentStates for detailed info

                    $relationship = @{
                        id = "$($user.id)_$($skuId)_license"
                        objectId = "$($user.id)_$($skuId)_license"
                        edgeType = "license"
                        sourceId = $user.id
                        sourceType = "user"
                        sourceDisplayName = $user.displayName ?? ""
                        sourceUserPrincipalName = $user.userPrincipalName ?? ""
                        sourceAccountEnabled = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }
                        sourceUserType = $user.userType ?? ""
                        targetId = $skuId
                        targetType = "license"
                        targetDisplayName = $skuPartNumber
                        targetSkuId = $skuId
                        targetSkuPartNumber = $skuPartNumber
                        assignmentSource = $assignmentSource
                        inheritedFromGroupId = $inheritedFromGroupId
                        inheritedFromGroupName = $inheritedFromGroupName
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.Licenses++
                }
            }

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed licenses buffer ($($stats.Licenses) total)"
            }
        }
        catch { Write-Warning "Failed to retrieve users batch for licenses: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "User licenses complete: $($stats.Licenses)"
    $perfTimer.Stop("Phase8_UserLicenses")
    #endregion

    #region Phase 9: OAuth2 Permission Grants (Consents)
    Write-Verbose "=== Phase 9: OAuth2 Permission Grants ==="

    # Build SP lookup for display names
    $spLookup = @{}
    $spLookupUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id,displayName,appId&`$top=$batchSize"
    while ($spLookupUri) {
        try {
            $spLookupResponse = Invoke-GraphWithRetry -Uri $spLookupUri -AccessToken $graphToken
            foreach ($sp in $spLookupResponse.value) {
                $spLookup[$sp.id] = @{
                    displayName = $sp.displayName
                    appId = $sp.appId
                }
            }
            $spLookupUri = $spLookupResponse.'@odata.nextLink'
        }
        catch { Write-Warning "Failed to build SP lookup: $_"; break }
    }
    Write-Verbose "Built lookup for $($spLookup.Count) service principals"

    $grantsUri = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$top=$batchSize"
    while ($grantsUri) {
        try {
            $response = Invoke-GraphWithRetry -Uri $grantsUri -AccessToken $graphToken

            foreach ($grant in $response.value) {
                $clientId = $grant.clientId ?? ""
                $resourceId = $grant.resourceId ?? ""
                $principalId = $grant.principalId  # Can be null for AllPrincipals consent

                $clientInfo = $spLookup[$clientId]
                $resourceInfo = $spLookup[$resourceId]

                $relationship = @{
                    id = $grant.id
                    objectId = $grant.id
                    edgeType = "oauth2PermissionGrant"
                    sourceId = if ($principalId) { $principalId } else { "AllPrincipals" }
                    sourceType = if ($principalId) { "user" } else { "tenant" }
                    sourceDisplayName = if ($principalId) { "User Consent" } else { "Admin Consent (All Users)" }
                    targetId = $resourceId
                    targetType = "servicePrincipal"
                    targetDisplayName = if ($resourceInfo) { $resourceInfo.displayName } else { "" }
                    targetAppId = if ($resourceInfo) { $resourceInfo.appId } else { "" }
                    clientId = $clientId
                    clientDisplayName = if ($clientInfo) { $clientInfo.displayName } else { "" }
                    clientAppId = if ($clientInfo) { $clientInfo.appId } else { "" }
                    consentType = $grant.consentType ?? ""
                    scope = $grant.scope ?? ""
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.OAuth2PermissionGrants++
            }
            $grantsUri = $response.'@odata.nextLink'

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed OAuth2 grants buffer ($($stats.OAuth2PermissionGrants) total)"
            }
        }
        catch { Write-Warning "OAuth2 permission grants batch error: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "OAuth2 permission grants complete: $($stats.OAuth2PermissionGrants)"
    #endregion

    #region Phase 10: App Role Assignments (BATCHED)
    Write-Verbose "=== Phase 10: App Role Assignments (using Graph $batch API) ==="
    $perfTimer.Start("Phase10_AppRoleAssignments")

    # Get all service principals and their app role assignments
    $spsForRolesUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id,displayName,appId,appRoles&`$top=$batchSize"

    while ($spsForRolesUri) {
        try {
            $spsResponse = Invoke-GraphWithRetry -Uri $spsForRolesUri -AccessToken $graphToken
            $spsForRolesUri = $spsResponse.'@odata.nextLink'

            # Build app role lookups for all SPs in this page
            $appRoleLookups = @{}
            foreach ($sp in $spsResponse.value) {
                $lookup = @{}
                foreach ($role in $sp.appRoles) {
                    $lookup[$role.id] = @{
                        displayName = $role.displayName
                        value = $role.value
                        description = $role.description
                    }
                }
                $appRoleLookups[$sp.id] = $lookup
            }

            # Build batch requests for all SPs in this page
            $batchRequests = @($spsResponse.value | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/servicePrincipals/$($_.id)/appRoleAssignedTo?`$top=$batchSize"
                }
            })

            # Execute batch request
            $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

            # Process results
            foreach ($sp in $spsResponse.value) {
                $assignmentsResponse = $batchResponses[$sp.id]
                $appRoleLookup = $appRoleLookups[$sp.id]

                # Skip if batch request failed for this SP
                if ($null -eq $assignmentsResponse) {
                    Write-Warning "Batch request failed for SP $($sp.displayName)"
                    continue
                }

                foreach ($assignment in $assignmentsResponse.value) {
                    $appRoleId = $assignment.appRoleId ?? ""
                    $roleInfo = $appRoleLookup[$appRoleId]

                    $relationship = @{
                        id = $assignment.id
                        objectId = $assignment.id
                        edgeType = "appRoleAssignment"
                        sourceId = $assignment.principalId ?? ""
                        sourceType = ($assignment.principalType ?? "").ToLower()
                        sourceDisplayName = $assignment.principalDisplayName ?? ""
                        targetId = $assignment.resourceId ?? ""
                        targetType = "servicePrincipal"
                        targetDisplayName = $assignment.resourceDisplayName ?? ""
                        targetAppId = $sp.appId ?? ""
                        appRoleId = $appRoleId
                        appRoleDisplayName = if ($roleInfo) { $roleInfo.displayName } else { "" }
                        appRoleValue = if ($roleInfo) { $roleInfo.value } else { "" }
                        createdDateTime = $assignment.createdDateTime ?? $null
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.AppRoleAssignments++
                }

                # Handle pagination for SPs with many assignments (>$batchSize)
                $nextLink = $assignmentsResponse.'@odata.nextLink'
                while ($nextLink) {
                    try {
                        $moreResponse = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                        $nextLink = $moreResponse.'@odata.nextLink'

                        foreach ($assignment in $moreResponse.value) {
                            $appRoleId = $assignment.appRoleId ?? ""
                            $roleInfo = $appRoleLookup[$appRoleId]

                            $relationship = @{
                                id = $assignment.id
                                objectId = $assignment.id
                                edgeType = "appRoleAssignment"
                                sourceId = $assignment.principalId ?? ""
                                sourceType = ($assignment.principalType ?? "").ToLower()
                                sourceDisplayName = $assignment.principalDisplayName ?? ""
                                targetId = $assignment.resourceId ?? ""
                                targetType = "servicePrincipal"
                                targetDisplayName = $assignment.resourceDisplayName ?? ""
                                targetAppId = $sp.appId ?? ""
                                appRoleId = $appRoleId
                                appRoleDisplayName = if ($roleInfo) { $roleInfo.displayName } else { "" }
                                appRoleValue = if ($roleInfo) { $roleInfo.value } else { "" }
                                createdDateTime = $assignment.createdDateTime ?? $null
                                collectionTimestamp = $timestampFormatted
                            }

                            [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                            $stats.AppRoleAssignments++
                        }
                    }
                    catch { Write-Warning "Failed to get additional app role assignments for SP $($sp.displayName): $_"; break }
                }
            }

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed app role assignments buffer ($($stats.AppRoleAssignments) total)"
            }
        }
        catch { Write-Warning "Failed to retrieve SPs for app role assignments: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "App role assignments complete: $($stats.AppRoleAssignments)"
    $perfTimer.Stop("Phase10_AppRoleAssignments")
    #endregion

    #region Phase 11: Group Owners (BATCHED)
    Write-Verbose "=== Phase 11: Group Owners (using Graph $batch API) ==="
    $perfTimer.Start("Phase11_GroupOwners")

    # Use the groups we already fetched in Phase 1
    # Process in chunks of batchSize (to match page size)
    $groupBatchSize = [Math]::Min($batchSize, 999)
    for ($i = 0; $i -lt $groups.Count; $i += $groupBatchSize) {
        $groupBatch = $groups[$i..([Math]::Min($i + $groupBatchSize - 1, $groups.Count - 1))]

        # Build batch requests for all groups in this batch
        $batchRequests = @($groupBatch | ForEach-Object {
            @{
                id = $_.id
                method = "GET"
                url = "/groups/$($_.id)/owners?`$select=id,displayName,userPrincipalName,mail"
            }
        })

        # Execute batch request
        $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

        # Process results
        foreach ($group in $groupBatch) {
            $ownersResponse = $batchResponses[$group.id]

            # Skip if batch request failed for this group
            if ($null -eq $ownersResponse) {
                Write-Warning "Batch request failed for group $($group.displayName)"
                continue
            }

            foreach ($owner in $ownersResponse.value) {
                $ownerType = ($owner.'@odata.type' -replace '#microsoft.graph.', '')

                $relationship = @{
                    id = "$($owner.id)_$($group.id)_groupOwner"
                    objectId = "$($owner.id)_$($group.id)_groupOwner"
                    edgeType = "groupOwner"
                    sourceId = $owner.id
                    sourceType = $ownerType
                    sourceDisplayName = $owner.displayName ?? ""
                    sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName ?? $null } else { $null }
                    targetId = $group.id
                    targetType = "group"
                    targetDisplayName = $group.displayName ?? ""
                    targetSecurityEnabled = if ($null -ne $group.securityEnabled) { $group.securityEnabled } else { $null }
                    targetMailEnabled = if ($null -ne $group.mailEnabled) { $group.mailEnabled } else { $null }
                    targetIsAssignableToRole = if ($null -ne $group.isAssignableToRole) { $group.isAssignableToRole } else { $null }
                    targetVisibility = $group.visibility ?? $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                $stats.GroupOwners++
            }

            # Handle pagination for groups with many owners (rare but possible)
            $nextLink = $ownersResponse.'@odata.nextLink'
            while ($nextLink) {
                try {
                    $moreResponse = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                    $nextLink = $moreResponse.'@odata.nextLink'

                    foreach ($owner in $moreResponse.value) {
                        $ownerType = ($owner.'@odata.type' -replace '#microsoft.graph.', '')

                        $relationship = @{
                            id = "$($owner.id)_$($group.id)_groupOwner"
                            objectId = "$($owner.id)_$($group.id)_groupOwner"
                            edgeType = "groupOwner"
                            sourceId = $owner.id
                            sourceType = $ownerType
                            sourceDisplayName = $owner.displayName ?? ""
                            sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName ?? $null } else { $null }
                            targetId = $group.id
                            targetType = "group"
                            targetDisplayName = $group.displayName ?? ""
                            targetSecurityEnabled = if ($null -ne $group.securityEnabled) { $group.securityEnabled } else { $null }
                            targetMailEnabled = if ($null -ne $group.mailEnabled) { $group.mailEnabled } else { $null }
                            targetIsAssignableToRole = if ($null -ne $group.isAssignableToRole) { $group.isAssignableToRole } else { $null }
                            targetVisibility = $group.visibility ?? $null
                            collectionTimestamp = $timestampFormatted
                        }

                        [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                        $stats.GroupOwners++
                    }
                }
                catch { Write-Warning "Failed to get additional owners for group $($group.displayName): $_"; break }
            }
        }

        # Periodic flush
        if ($jsonL.Length -ge ($writeThreshold * 300)) {
            Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
            Write-Verbose "Flushed group owners buffer ($($stats.GroupOwners) total)"
        }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Group owners complete: $($stats.GroupOwners)"
    $perfTimer.Stop("Phase11_GroupOwners")
    #endregion

    #region Phase 12: Device Owners (BATCHED)
    Write-Verbose "=== Phase 12: Device Owners (using Graph $batch API) ==="
    $perfTimer.Start("Phase12_DeviceOwners")

    # Get all devices
    $devicesUri = "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,deviceId,operatingSystem,trustType&`$top=$batchSize"

    while ($devicesUri) {
        try {
            $devicesResponse = Invoke-GraphWithRetry -Uri $devicesUri -AccessToken $graphToken
            $devicesUri = $devicesResponse.'@odata.nextLink'

            # Build batch requests for all devices in this page
            $batchRequests = @($devicesResponse.value | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/devices/$($_.id)/registeredOwners?`$select=id,displayName,userPrincipalName"
                }
            })

            # Execute batch request
            $batchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

            # Process results
            foreach ($device in $devicesResponse.value) {
                $ownersResponse = $batchResponses[$device.id]

                # Skip if batch request failed for this device
                if ($null -eq $ownersResponse) {
                    Write-Warning "Batch request failed for device $($device.displayName)"
                    continue
                }

                foreach ($owner in $ownersResponse.value) {
                    $ownerType = ($owner.'@odata.type' -replace '#microsoft.graph.', '')

                    $relationship = @{
                        id = "$($owner.id)_$($device.id)_deviceOwner"
                        objectId = "$($owner.id)_$($device.id)_deviceOwner"
                        edgeType = "deviceOwner"
                        sourceId = $owner.id
                        sourceType = $ownerType
                        sourceDisplayName = $owner.displayName ?? ""
                        sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName ?? $null } else { $null }
                        targetId = $device.id
                        targetType = "device"
                        targetDisplayName = $device.displayName ?? ""
                        targetDeviceId = $device.deviceId ?? ""
                        targetOperatingSystem = $device.operatingSystem ?? ""
                        targetTrustType = $device.trustType ?? ""
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                    $stats.DeviceOwners++
                }
            }

            # Periodic flush
            if ($jsonL.Length -ge ($writeThreshold * 300)) {
                Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
                Write-Verbose "Flushed device owners buffer ($($stats.DeviceOwners) total)"
            }
        }
        catch { Write-Warning "Failed to retrieve devices batch: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Device owners complete: $($stats.DeviceOwners)"
    $perfTimer.Stop("Phase12_DeviceOwners")
    #endregion

    #region Phase 13: Conditional Access Policy Edges
    Write-Verbose "=== Phase 13: Conditional Access Policy Edges ==="

    # Get all Conditional Access policies
    $caPoliciesUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"

    while ($caPoliciesUri) {
        try {
            $response = Invoke-GraphWithRetry -Uri $caPoliciesUri -AccessToken $graphToken

            foreach ($policy in $response.value) {
                $policyId = $policy.id
                $policyState = $policy.state
                $policyDisplayName = $policy.displayName

                # Extract grant controls
                $grantControls = $policy.grantControls.builtInControls ?? @()
                $requiresMfa = $grantControls -contains 'mfa'
                $blocksAccess = $grantControls -contains 'block'
                $requiresCompliantDevice = $grantControls -contains 'compliantDevice'
                $requiresHybridAzureADJoin = $grantControls -contains 'domainJoinedDevice'
                $requiresApprovedApp = $grantControls -contains 'approvedApplication'
                $requiresAppProtection = $grantControls -contains 'compliantApplication'

                $clientAppTypes = $policy.conditions.clientAppTypes ?? @()
                $hasLocationCondition = ($null -ne $policy.conditions.locations)
                $hasRiskCondition = (($policy.conditions.signInRiskLevels ?? @()).Count -gt 0) -or
                                   (($policy.conditions.userRiskLevels ?? @()).Count -gt 0)

                # Common edge properties
                $baseEdge = @{
                    sourceId = $policyId
                    sourceType = "conditionalAccessPolicy"
                    sourceDisplayName = $policyDisplayName
                    policyState = $policyState
                    requiresMfa = $requiresMfa
                    blocksAccess = $blocksAccess
                    requiresCompliantDevice = $requiresCompliantDevice
                    requiresHybridAzureADJoin = $requiresHybridAzureADJoin
                    requiresApprovedApp = $requiresApprovedApp
                    requiresAppProtection = $requiresAppProtection
                    clientAppTypes = $clientAppTypes
                    hasLocationCondition = $hasLocationCondition
                    hasRiskCondition = $hasRiskCondition
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                #region Process User/Group Inclusions
                $userConditions = $policy.conditions.users

                # Include users
                foreach ($userId in ($userConditions.includeUsers ?? @())) {
                    $targetType = switch ($userId) {
                        'All' { 'allUsers' }
                        'GuestsOrExternalUsers' { 'allGuestUsers' }
                        default { 'user' }
                    }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${userId}_caPolicyTargetsPrincipal"
                    $edge.objectId = "${policyId}_${userId}_caPolicyTargetsPrincipal"
                    $edge.edgeType = "caPolicyTargetsPrincipal"
                    $edge.targetId = $userId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Include groups
                foreach ($groupId in ($userConditions.includeGroups ?? @())) {
                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${groupId}_caPolicyTargetsPrincipal"
                    $edge.objectId = "${policyId}_${groupId}_caPolicyTargetsPrincipal"
                    $edge.edgeType = "caPolicyTargetsPrincipal"
                    $edge.targetId = $groupId
                    $edge.targetType = "group"
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Include roles
                foreach ($roleId in ($userConditions.includeRoles ?? @())) {
                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${roleId}_caPolicyTargetsPrincipal"
                    $edge.objectId = "${policyId}_${roleId}_caPolicyTargetsPrincipal"
                    $edge.edgeType = "caPolicyTargetsPrincipal"
                    $edge.targetId = $roleId
                    $edge.targetType = "directoryRole"
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Exclude users
                foreach ($userId in ($userConditions.excludeUsers ?? @())) {
                    $targetType = if ($userId -eq 'GuestsOrExternalUsers') { 'allGuestUsers' } else { 'user' }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${userId}_caPolicyExcludesPrincipal"
                    $edge.objectId = "${policyId}_${userId}_caPolicyExcludesPrincipal"
                    $edge.edgeType = "caPolicyExcludesPrincipal"
                    $edge.targetId = $userId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Exclude groups
                foreach ($groupId in ($userConditions.excludeGroups ?? @())) {
                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${groupId}_caPolicyExcludesPrincipal"
                    $edge.objectId = "${policyId}_${groupId}_caPolicyExcludesPrincipal"
                    $edge.edgeType = "caPolicyExcludesPrincipal"
                    $edge.targetId = $groupId
                    $edge.targetType = "group"
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Exclude roles
                foreach ($roleId in ($userConditions.excludeRoles ?? @())) {
                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${roleId}_caPolicyExcludesPrincipal"
                    $edge.objectId = "${policyId}_${roleId}_caPolicyExcludesPrincipal"
                    $edge.edgeType = "caPolicyExcludesPrincipal"
                    $edge.targetId = $roleId
                    $edge.targetType = "directoryRole"
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }
                #endregion

                #region Process Application Inclusions/Exclusions
                $appConditions = $policy.conditions.applications

                # Include applications
                foreach ($appId in ($appConditions.includeApplications ?? @())) {
                    $targetType = switch ($appId) {
                        'All' { 'allApps' }
                        'Office365' { 'office365' }
                        default { 'application' }
                    }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${appId}_caPolicyTargetsApplication"
                    $edge.objectId = "${policyId}_${appId}_caPolicyTargetsApplication"
                    $edge.edgeType = "caPolicyTargetsApplication"
                    $edge.targetId = $appId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Exclude applications
                foreach ($appId in ($appConditions.excludeApplications ?? @())) {
                    $targetType = if ($appId -eq 'Office365') { 'office365' } else { 'application' }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${appId}_caPolicyExcludesApplication"
                    $edge.objectId = "${policyId}_${appId}_caPolicyExcludesApplication"
                    $edge.edgeType = "caPolicyExcludesApplication"
                    $edge.targetId = $appId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }
                #endregion

                #region Process Location Conditions
                $locationConditions = $policy.conditions.locations

                # Include locations
                foreach ($locationId in ($locationConditions.includeLocations ?? @())) {
                    $targetType = switch ($locationId) {
                        'All' { 'allLocations' }
                        'AllTrusted' { 'allTrustedLocations' }
                        default { 'namedLocation' }
                    }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${locationId}_caPolicyUsesLocation"
                    $edge.objectId = "${policyId}_${locationId}_caPolicyUsesLocation"
                    $edge.edgeType = "caPolicyUsesLocation"
                    $edge.targetId = $locationId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""
                    $edge.locationUsageType = "include"

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }

                # Exclude locations
                foreach ($locationId in ($locationConditions.excludeLocations ?? @())) {
                    $targetType = switch ($locationId) {
                        'AllTrusted' { 'allTrustedLocations' }
                        default { 'namedLocation' }
                    }

                    $edge = $baseEdge.Clone()
                    $edge.id = "${policyId}_${locationId}_caPolicyUsesLocation_exclude"
                    $edge.objectId = "${policyId}_${locationId}_caPolicyUsesLocation_exclude"
                    $edge.edgeType = "caPolicyUsesLocation"
                    $edge.targetId = $locationId
                    $edge.targetType = $targetType
                    $edge.targetDisplayName = ""
                    $edge.locationUsageType = "exclude"

                    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                    $stats.CaPolicyEdges++
                }
                #endregion
            }

            $caPoliciesUri = $response.'@odata.nextLink'
        }
        catch { Write-Warning "Failed to retrieve CA policies: $_"; break }
    }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "CA policy edges complete: $($stats.CaPolicyEdges)"
    #endregion

    #region Phase 14: Role Management Policy Edges
    Write-Verbose "=== Phase 14: Role Management Policy Edges ==="

    # Get role management policy assignments (links policies to directory roles)
    $policyAssignmentsUri = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'"

    try {
        $assignmentsResponse = Invoke-GraphWithRetry -Uri $policyAssignmentsUri -AccessToken $graphToken

        foreach ($assignment in $assignmentsResponse.value) {
            $policyId = $assignment.policyId
            $roleDefinitionId = $assignment.roleDefinitionId

            # Get the policy details with rules expanded
            try {
                $policyUri = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/${policyId}?`$expand=rules"
                $policyResponse = Invoke-GraphWithRetry -Uri $policyUri -AccessToken $graphToken

                # Extract rule settings
                $requiresMfaOnActivation = $false
                $requiresApproval = $false
                $requiresJustification = $false
                $requiresTicketInfo = $false
                $maxActivationDurationHours = $null
                $permanentAssignmentAllowed = $true
                $eligibleAssignmentMaxDurationDays = $null

                foreach ($rule in $policyResponse.rules) {
                    $ruleType = $rule.'@odata.type'
                    $ruleId = $rule.id

                    switch -Wildcard ($ruleType) {
                        '*unifiedRoleManagementPolicyEnablementRule' {
                            if ($ruleId -eq 'Enablement_EndUser_Assignment') {
                                $enabledRules = $rule.enabledRules ?? @()
                                $requiresMfaOnActivation = $enabledRules -contains 'MultiFactorAuthentication'
                                $requiresJustification = $enabledRules -contains 'Justification'
                                $requiresTicketInfo = $enabledRules -contains 'Ticketing'
                            }
                        }
                        '*unifiedRoleManagementPolicyApprovalRule' {
                            if ($ruleId -eq 'Approval_EndUser_Assignment') {
                                $setting = $rule.setting
                                $requiresApproval = $setting.isApprovalRequired ?? $false
                            }
                        }
                        '*unifiedRoleManagementPolicyExpirationRule' {
                            if ($ruleId -eq 'Expiration_EndUser_Assignment') {
                                # Maximum activation duration
                                $maxDuration = $rule.maximumDuration
                                if ($maxDuration -match 'PT(\d+)H') {
                                    $maxActivationDurationHours = [int]$matches[1]
                                }
                            }
                            elseif ($ruleId -eq 'Expiration_Admin_Eligibility') {
                                # Eligible assignment settings
                                $permanentAssignmentAllowed = -not ($rule.isExpirationRequired ?? $false)
                                $maxDuration = $rule.maximumDuration
                                if ($maxDuration -match 'P(\d+)D') {
                                    $eligibleAssignmentMaxDurationDays = [int]$matches[1]
                                }
                            }
                        }
                    }
                }

                $edge = @{
                    id = "${policyId}_${roleDefinitionId}_rolePolicyAssignment"
                    objectId = "${policyId}_${roleDefinitionId}_rolePolicyAssignment"
                    edgeType = "rolePolicyAssignment"
                    sourceId = $policyId
                    sourceType = "roleManagementPolicy"
                    sourceDisplayName = $policyResponse.displayName ?? ""
                    targetId = $roleDefinitionId
                    targetType = "directoryRole"
                    targetDisplayName = ""
                    requiresMfaOnActivation = $requiresMfaOnActivation
                    requiresApproval = $requiresApproval
                    requiresJustification = $requiresJustification
                    requiresTicketInfo = $requiresTicketInfo
                    maxActivationDurationHours = $maxActivationDurationHours
                    permanentAssignmentAllowed = $permanentAssignmentAllowed
                    eligibleAssignmentMaxDurationDays = $eligibleAssignmentMaxDurationDays
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
                $stats.RolePolicyEdges++
            }
            catch { Write-Warning "Failed to get policy details for $policyId : $_" }
        }
    }
    catch { Write-Warning "Failed to retrieve role management policy assignments: $_" }

    Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
    Write-Verbose "Role policy edges complete: $($stats.RolePolicyEdges)"
    #endregion

    # Cleanup
    $jsonL = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    $pimRequestCount = if ($stats.PimRequests) { $stats.PimRequests } else { 0 }
    $totalRelationships = $stats.GroupMembershipsDirect + $stats.GroupMembershipsTransitive + $stats.DirectoryRoles + $stats.PimEligible + $stats.PimActive + $pimRequestCount + $stats.PimGroupEligible + $stats.PimGroupActive + $stats.AzureRbac + $stats.AppOwners + $stats.SpOwners + $stats.Licenses + $stats.OAuth2PermissionGrants + $stats.AppRoleAssignments + $stats.GroupOwners + $stats.DeviceOwners + $stats.CaPolicyEdges + $stats.RolePolicyEdges

    # Log performance timing for batch optimization analysis
    $perfTimer.LogSummary("CollectRelationships")
    $phaseTiming = $perfTimer.Summary()

    Write-Verbose "Combined relationships collection complete: $totalRelationships total"

    return @{
        Success = $true
        Timestamp = $timestamp
        EdgesBlobName = $edgesBlobName
        RelationshipCount = $totalRelationships
        EdgeCount = $totalRelationships
        Stats = $stats
        PhaseTiming = $phaseTiming
        Summary = @{
            timestamp = $timestampFormatted
            totalRelationships = $totalRelationships
            groupMembershipsDirect = $stats.GroupMembershipsDirect
            groupMembershipsTransitive = $stats.GroupMembershipsTransitive
            directoryRoles = $stats.DirectoryRoles
            pimEligible = $stats.PimEligible
            pimActive = $stats.PimActive
            pimRequests = $pimRequestCount
            pimGroupEligible = $stats.PimGroupEligible
            pimGroupActive = $stats.PimGroupActive
            azureRbac = $stats.AzureRbac
            appOwners = $stats.AppOwners
            spOwners = $stats.SpOwners
            licenses = $stats.Licenses
            oauth2PermissionGrants = $stats.OAuth2PermissionGrants
            appRoleAssignments = $stats.AppRoleAssignments
            groupOwners = $stats.GroupOwners
            deviceOwners = $stats.DeviceOwners
            caPolicyEdges = $stats.CaPolicyEdges
            rolePolicyEdges = $stats.RolePolicyEdges
            phaseTiming = $phaseTiming
        }
    }
}
catch {
    Write-Error "Combined relationships collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
