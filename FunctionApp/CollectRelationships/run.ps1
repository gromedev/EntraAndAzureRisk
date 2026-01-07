<#
.SYNOPSIS
    Combined collector for relationship data
.DESCRIPTION
    V2 Architecture: Single collector for all relationship types → relationships.jsonl

    Collects:
    1. Group memberships (groups → members)
    2. Directory role members (roles → members)
    3. PIM eligible role assignments
    4. PIM active role assignments
    5. PIM group eligible memberships
    6. PIM group active memberships
    7. Azure RBAC assignments

    All output to single relationships.jsonl with relationType discriminator.
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

    # Generate timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
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
        GroupMemberships = 0
        DirectoryRoles = 0
        PimEligible = 0
        PimActive = 0
        PimGroupEligible = 0
        PimGroupActive = 0
        AzureRbac = 0
    }

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-relationships.jsonl"
    Write-Verbose "Initializing append blob: $blobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $blobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
    }

    # Reusable buffer
    $jsonL = New-Object System.Text.StringBuilder(2097152)
    $writeThreshold = 5000

    # Helper function to flush buffer
    function Flush-Buffer {
        if ($jsonL.Length -gt 0) {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $blobName `
                           -Content $jsonL.ToString() `
                           -AccessToken $storageToken `
                           -MaxRetries 3 `
                           -BaseRetryDelaySeconds 2
            $jsonL.Clear()
        }
    }

    #region Phase 1: Group Memberships
    Write-Verbose "=== Phase 1: Group Memberships ==="

    # Get all groups
    $groupSelectFields = "id,displayName,securityEnabled,mailEnabled,groupTypes,isAssignableToRole,visibility"
    $groupsNextLink = "https://graph.microsoft.com/beta/groups?`$select=$groupSelectFields&`$top=$batchSize"

    $groups = @()
    while ($groupsNextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $groupsNextLink -AccessToken $graphToken
            $groups += $response.value
            $groupsNextLink = $response.'@odata.nextLink'
        }
        catch { Write-Warning "Failed to retrieve groups: $_"; break }
    }

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

                        $relationship = @{
                            id = "$($member.id)_$($group.id)_groupMember"
                            objectId = "$($member.id)_$($group.id)_groupMember"
                            relationType = "groupMember"
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
                            collectionTimestamp = $timestampFormatted
                        }

                        [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                        $stats.GroupMemberships++
                    }
                }
                catch { Write-Warning "Failed to get members for group $($group.displayName): $_"; break }
            }
        }
        catch { Write-Warning "Error processing group $($group.displayName): $_" }

        # Periodic flush
        if ($jsonL.Length -ge ($writeThreshold * 300)) {
            Flush-Buffer
            Write-Verbose "Flushed group memberships buffer ($($stats.GroupMemberships) total)"
        }
    }
    Flush-Buffer
    Write-Verbose "Group memberships complete: $($stats.GroupMemberships)"
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

    try {
        $rolesResponse = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/directoryRoles" -AccessToken $graphToken
        $roles = $rolesResponse.value

        foreach ($role in $roles) {
            $isPrivileged = $privilegedRoleTemplates -contains $role.roleTemplateId
            $membersUri = "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members"
            $nextMembersLink = $membersUri

            while ($nextMembersLink) {
                try {
                    $membersResponse = Invoke-GraphWithRetry -Uri $nextMembersLink -AccessToken $graphToken
                    $nextMembersLink = $membersResponse.'@odata.nextLink'

                    foreach ($member in $membersResponse.value) {
                        $memberType = ($member.'@odata.type' -replace '#microsoft.graph.', '')

                        $relationship = @{
                            id = "$($member.id)_$($role.id)_directoryRole"
                            objectId = "$($member.id)_$($role.id)_directoryRole"
                            relationType = "directoryRole"
                            sourceId = $member.id
                            sourceType = $memberType
                            sourceDisplayName = $member.displayName ?? ""
                            targetId = $role.id
                            targetType = "directoryRole"
                            targetDisplayName = $role.displayName ?? ""
                            targetRoleTemplateId = $role.roleTemplateId ?? ""
                            targetIsPrivileged = $isPrivileged
                            targetIsBuiltIn = $true
                            sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName ?? $null } else { $null }
                            collectionTimestamp = $timestampFormatted
                        }

                        [void]$jsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
                        $stats.DirectoryRoles++
                    }
                }
                catch { Write-Warning "Failed to get members for role $($role.displayName): $_"; break }
            }
        }
    }
    catch { Write-Warning "Failed to retrieve directory roles: $_" }

    Flush-Buffer
    Write-Verbose "Directory roles complete: $($stats.DirectoryRoles)"
    #endregion

    #region Phase 3: PIM Role Assignments
    Write-Verbose "=== Phase 3: PIM Role Assignments ==="

    # Eligible roles
    $selectFields = "id,principalId,roleDefinitionId,memberType,status,scheduleInfo,createdDateTime,modifiedDateTime"
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            foreach ($assignment in $response.value) {
                $principalId = $assignment.principalId ?? ""
                $roleDefId = $assignment.roleDefinitionId ?? ""

                $relationship = @{
                    id = "${principalId}_${roleDefId}_pimEligible"
                    objectId = "${principalId}_${roleDefId}_pimEligible"
                    relationType = "pimEligible"
                    assignmentType = "eligible"
                    sourceId = $principalId
                    sourceType = ($assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? "")
                    sourceDisplayName = $assignment.principal.displayName ?? ""
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
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentSchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            foreach ($assignment in $response.value) {
                $principalId = $assignment.principalId ?? ""
                $roleDefId = $assignment.roleDefinitionId ?? ""

                $relationship = @{
                    id = "${principalId}_${roleDefId}_pimActive"
                    objectId = "${principalId}_${roleDefId}_pimActive"
                    relationType = "pimActive"
                    assignmentType = "active"
                    sourceId = $principalId
                    sourceType = ($assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? "")
                    sourceDisplayName = $assignment.principal.displayName ?? ""
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

    Flush-Buffer
    Write-Verbose "PIM roles complete: $($stats.PimEligible) eligible, $($stats.PimActive) active"
    #endregion

    #region Phase 4: PIM Group Memberships
    Write-Verbose "=== Phase 4: PIM Group Memberships ==="

    # Get role-assignable groups
    $roleAssignableGroups = @()
    $groupsLink = "https://graph.microsoft.com/v1.0/groups?`$filter=isAssignableToRole eq true&`$select=id,displayName&`$top=999"
    while ($groupsLink) {
        try {
            $groupsResponse = Invoke-GraphWithRetry -Uri $groupsLink -AccessToken $graphToken
            $roleAssignableGroups += $groupsResponse.value
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
                        relationType = "pimGroupEligible"
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
                        relationType = "pimGroupActive"
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

    Flush-Buffer
    Write-Verbose "PIM groups complete: $($stats.PimGroupEligible) eligible, $($stats.PimGroupActive) active"
    #endregion

    #region Phase 5: Azure RBAC Assignments
    Write-Verbose "=== Phase 5: Azure RBAC Assignments ==="

    # Discover subscriptions
    $subscriptions = Get-AzureManagementPagedResults `
        -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" `
        -AccessToken $azureToken

    Write-Verbose "Found $($subscriptions.Count) Azure subscriptions"

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

                $relationship = @{
                    id = "${principalId}_${scope}_azureRbac"
                    objectId = "${principalId}_${scope}_azureRbac"
                    relationType = "azureRbac"
                    sourceId = $principalId
                    sourceType = $assignment.properties.principalType ?? ""
                    targetId = $roleDefId
                    targetType = "azureRole"
                    targetRoleDefinitionId = $roleDefId
                    targetRoleDefinitionName = ($roleDefId -split '/')[-1]
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
            Flush-Buffer
        }
    }

    Flush-Buffer
    Write-Verbose "Azure RBAC complete: $($stats.AzureRbac)"
    #endregion

    # Cleanup
    $jsonL = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    $totalRelationships = $stats.GroupMemberships + $stats.DirectoryRoles + $stats.PimEligible + $stats.PimActive + $stats.PimGroupEligible + $stats.PimGroupActive + $stats.AzureRbac

    Write-Verbose "Combined relationships collection complete: $totalRelationships total"

    return @{
        Success = $true
        Timestamp = $timestamp
        BlobName = $blobName
        RelationshipCount = $totalRelationships
        Stats = $stats
        Summary = @{
            timestamp = $timestampFormatted
            totalRelationships = $totalRelationships
            groupMemberships = $stats.GroupMemberships
            directoryRoles = $stats.DirectoryRoles
            pimEligible = $stats.PimEligible
            pimActive = $stats.PimActive
            pimGroupEligible = $stats.PimGroupEligible
            pimGroupActive = $stats.PimGroupActive
            azureRbac = $stats.AzureRbac
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
