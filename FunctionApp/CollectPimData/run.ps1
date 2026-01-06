<#
.SYNOPSIS
    Combined collector for PIM-related data: roles, group memberships, and policies
.DESCRIPTION
    Consolidates three fast PIM collections into a single activity function:
    1. PIM role assignments (eligible and active)
    2. PIM group memberships (eligible and active)
    3. Role management policies and assignments

    Each collection outputs to its own blob file within the same timestamp folder.
    Runs sequentially within the function but reduces orchestrator complexity.
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
    return @{
        Success = $false
        Error = $errorMsg
    }
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
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting combined PIM data collection"

    # Generate timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens (cached)
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{
            Success = $false
            Error = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Results tracking
    $results = @{
        PimRoles = @{ Success = $false; BlobName = $null; Count = 0 }
        PimGroups = @{ Success = $false; BlobName = $null; Count = 0 }
        RolePolicies = @{ Success = $false; BlobName = $null; Count = 0 }
    }

    #region 1. Collect PIM Role Assignments
    Write-Verbose "=== Phase 1: Collecting PIM role assignments ==="

    $rolesJsonL = New-Object System.Text.StringBuilder(1048576)
    $pimRolesCount = 0
    $eligibleRolesCount = 0
    $activeRolesCount = 0
    $rolesBlobName = "$timestamp/$timestamp-entra-pim-roles.jsonl"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $rolesBlobName `
                              -AccessToken $storageToken

        # Collect eligible role assignments
        $selectFields = "id,principalId,roleDefinitionId,memberType,status,scheduleInfo,createdDateTime,modifiedDateTime"
        $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($assignment in $response.value) {
                    # Generate objectId from principalId + roleDefinitionId + type if API doesn't provide id
                    $objId = if ($assignment.id) { $assignment.id } else { "$($assignment.principalId)_$($assignment.roleDefinitionId)_eligible" }
                    $assignmentObj = @{
                        objectId = $objId
                        assignmentType = "eligible"
                        principalId = $assignment.principalId ?? ""
                        roleDefinitionId = $assignment.roleDefinitionId ?? ""
                        roleDefinitionName = $assignment.roleDefinition.displayName ?? ""
                        roleTemplateId = $assignment.roleDefinition.templateId ?? ""
                        principalDisplayName = $assignment.principal.displayName ?? ""
                        principalType = $assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                        memberType = $assignment.memberType ?? ""
                        status = $assignment.status ?? ""
                        scheduleInfo = $assignment.scheduleInfo ?? @{}
                        createdDateTime = $assignment.createdDateTime ?? ""
                        modifiedDateTime = $assignment.modifiedDateTime ?? ""
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$rolesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
                    $pimRolesCount++
                    $eligibleRolesCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Eligible roles batch error: $_"; break }
        }

        # Collect active role assignments
        $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentSchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($assignment in $response.value) {
                    # Generate objectId from principalId + roleDefinitionId + type if API doesn't provide id
                    $objId = if ($assignment.id) { $assignment.id } else { "$($assignment.principalId)_$($assignment.roleDefinitionId)_active" }
                    $assignmentObj = @{
                        objectId = $objId
                        assignmentType = "active"
                        principalId = $assignment.principalId ?? ""
                        roleDefinitionId = $assignment.roleDefinitionId ?? ""
                        roleDefinitionName = $assignment.roleDefinition.displayName ?? ""
                        roleTemplateId = $assignment.roleDefinition.templateId ?? ""
                        principalDisplayName = $assignment.principal.displayName ?? ""
                        principalType = $assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                        memberType = $assignment.memberType ?? ""
                        status = $assignment.status ?? ""
                        scheduleInfo = $assignment.scheduleInfo ?? @{}
                        createdDateTime = $assignment.createdDateTime ?? ""
                        modifiedDateTime = $assignment.modifiedDateTime ?? ""
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$rolesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
                    $pimRolesCount++
                    $activeRolesCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Active roles batch error: $_"; break }
        }

        # Write to blob
        if ($rolesJsonL.Length -gt 0) {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $rolesBlobName `
                           -Content $rolesJsonL.ToString() `
                           -AccessToken $storageToken
        }

        $results.PimRoles = @{
            Success = $true
            BlobName = $rolesBlobName
            Count = $pimRolesCount
            EligibleCount = $eligibleRolesCount
            ActiveCount = $activeRolesCount
        }
        Write-Verbose "PIM roles complete: $pimRolesCount assignments ($eligibleRolesCount eligible, $activeRolesCount active)"
    }
    catch {
        Write-Warning "PIM roles collection failed: $_"
        $results.PimRoles.Error = $_.Exception.Message
    }
    $rolesJsonL = $null
    #endregion

    #region 2. Collect PIM Group Memberships
    Write-Verbose "=== Phase 2: Collecting PIM group memberships ==="

    $groupsJsonL = New-Object System.Text.StringBuilder(1048576)
    $pimGroupsCount = 0
    $eligibleGroupsCount = 0
    $activeGroupsCount = 0
    $groupsBlobName = "$timestamp/$timestamp-pim-groups.jsonl"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $groupsBlobName `
                              -AccessToken $storageToken

        # Collect eligible group memberships
        $selectFields = "id,principalId,groupId,accessId,memberType,status,scheduleInfo,createdDateTime"
        $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($membership in $response.value) {
                    # Generate objectId from principalId + groupId + accessId + type if API doesn't provide id
                    $objId = if ($membership.id) { $membership.id } else { "$($membership.principalId)_$($membership.groupId)_$($membership.accessId)_eligible" }
                    $membershipObj = @{
                        objectId = $objId
                        assignmentType = "eligible"
                        principalId = $membership.principalId ?? ""
                        groupId = $membership.groupId ?? ""
                        groupDisplayName = $membership.group.displayName ?? ""
                        accessId = $membership.accessId ?? ""
                        principalDisplayName = $membership.principal.displayName ?? ""
                        principalType = $membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                        memberType = $membership.memberType ?? ""
                        status = $membership.status ?? ""
                        scheduleInfo = $membership.scheduleInfo ?? @{}
                        createdDateTime = $membership.createdDateTime ?? ""
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$groupsJsonL.AppendLine(($membershipObj | ConvertTo-Json -Compress))
                    $pimGroupsCount++
                    $eligibleGroupsCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Eligible groups batch error: $_"; break }
        }

        # Collect active group memberships
        $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentSchedules?`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($membership in $response.value) {
                    # Generate objectId from principalId + groupId + accessId + type if API doesn't provide id
                    $objId = if ($membership.id) { $membership.id } else { "$($membership.principalId)_$($membership.groupId)_$($membership.accessId)_active" }
                    $membershipObj = @{
                        objectId = $objId
                        assignmentType = "active"
                        principalId = $membership.principalId ?? ""
                        groupId = $membership.groupId ?? ""
                        groupDisplayName = $membership.group.displayName ?? ""
                        accessId = $membership.accessId ?? ""
                        principalDisplayName = $membership.principal.displayName ?? ""
                        principalType = $membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                        memberType = $membership.memberType ?? ""
                        status = $membership.status ?? ""
                        scheduleInfo = $membership.scheduleInfo ?? @{}
                        createdDateTime = $membership.createdDateTime ?? ""
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$groupsJsonL.AppendLine(($membershipObj | ConvertTo-Json -Compress))
                    $pimGroupsCount++
                    $activeGroupsCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Active groups batch error: $_"; break }
        }

        # Write to blob
        if ($groupsJsonL.Length -gt 0) {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $groupsBlobName `
                           -Content $groupsJsonL.ToString() `
                           -AccessToken $storageToken
        }

        $results.PimGroups = @{
            Success = $true
            BlobName = $groupsBlobName
            Count = $pimGroupsCount
            EligibleCount = $eligibleGroupsCount
            ActiveCount = $activeGroupsCount
        }
        Write-Verbose "PIM groups complete: $pimGroupsCount memberships ($eligibleGroupsCount eligible, $activeGroupsCount active)"
    }
    catch {
        Write-Warning "PIM groups collection failed: $_"
        $results.PimGroups.Error = $_.Exception.Message
    }
    $groupsJsonL = $null
    #endregion

    #region 3. Collect Role Policies
    Write-Verbose "=== Phase 3: Collecting role management policies ==="

    $policiesJsonL = New-Object System.Text.StringBuilder(1048576)
    $policyCount = 0
    $assignmentCount = 0
    $policiesBlobName = "$timestamp/$timestamp-role-policies.jsonl"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $policiesBlobName `
                              -AccessToken $storageToken

        # Collect role management policies (requires filter by scope for directory roles)
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=rules,effectiveRules&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($policy in $response.value) {
                    $policyObj = @{
                        objectId = $policy.id ?? ""
                        displayName = $policy.displayName ?? ""
                        description = $policy.description ?? ""
                        isOrganizationDefault = $policy.isOrganizationDefault ?? $false
                        scope = $policy.scope ?? ""
                        scopeId = $policy.scopeId ?? ""
                        scopeType = $policy.scopeType ?? ""
                        rules = $policy.rules ?? @()
                        effectiveRules = $policy.effectiveRules ?? @()
                        lastModifiedDateTime = $policy.lastModifiedDateTime ?? ""
                        lastModifiedBy = $policy.lastModifiedBy ?? @{}
                        collectionTimestamp = $timestampFormatted
                        dataType = "policy"
                    }
                    [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                    $policyCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Policies batch error: $_"; break }
        }

        # Collect policy assignments (requires filter by scope for directory roles)
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($assignment in $response.value) {
                    $assignmentObj = @{
                        objectId = $assignment.id ?? ""
                        policyId = $assignment.policyId ?? ""
                        roleDefinitionId = $assignment.roleDefinitionId ?? ""
                        scope = $assignment.scope ?? ""
                        scopeId = $assignment.scopeId ?? ""
                        scopeType = $assignment.scopeType ?? ""
                        policyDisplayName = $assignment.policy.displayName ?? ""
                        policyIsOrganizationDefault = $assignment.policy.isOrganizationDefault ?? $false
                        collectionTimestamp = $timestampFormatted
                        dataType = "policyAssignment"
                    }
                    [void]$policiesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
                    $assignmentCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch { Write-Warning "Policy assignments batch error: $_"; break }
        }

        # Write to blob
        if ($policiesJsonL.Length -gt 0) {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
        }

        $results.RolePolicies = @{
            Success = $true
            BlobName = $policiesBlobName
            Count = $policyCount + $assignmentCount
            PolicyCount = $policyCount
            AssignmentCount = $assignmentCount
        }
        Write-Verbose "Role policies complete: $policyCount policies, $assignmentCount assignments"
    }
    catch {
        Write-Warning "Role policies collection failed: $_"
        $results.RolePolicies.Error = $_.Exception.Message
    }
    $policiesJsonL = $null
    #endregion

    # Garbage collection
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    # Determine overall success
    $overallSuccess = $results.PimRoles.Success -or $results.PimGroups.Success -or $results.RolePolicies.Success
    $totalCount = $results.PimRoles.Count + $results.PimGroups.Count + $results.RolePolicies.Count

    Write-Verbose "Combined PIM collection complete: $totalCount total items"

    return @{
        Success = $overallSuccess
        Timestamp = $timestamp

        # Individual blob paths (for potential future indexing)
        PimRolesBlobName = $results.PimRoles.BlobName
        PimGroupsBlobName = $results.PimGroups.BlobName
        RolePoliciesBlobName = $results.RolePolicies.BlobName

        # Counts for orchestrator summary
        PimRoleCount = $results.PimRoles.Count
        PimGroupMembershipCount = $results.PimGroups.Count
        RolePolicyCount = $results.RolePolicies.Count
        TotalPimDataCount = $totalCount

        # Detailed results
        Results = $results

        Summary = @{
            timestamp = $timestampFormatted
            totalCount = $totalCount
            pimRoles = @{
                total = $results.PimRoles.Count
                eligible = $results.PimRoles.EligibleCount
                active = $results.PimRoles.ActiveCount
            }
            pimGroups = @{
                total = $results.PimGroups.Count
                eligible = $results.PimGroups.EligibleCount
                active = $results.PimGroups.ActiveCount
            }
            rolePolicies = @{
                total = $results.RolePolicies.Count
                policies = $results.RolePolicies.PolicyCount
                assignments = $results.RolePolicies.AssignmentCount
            }
        }
    }
}
catch {
    Write-Error "Combined PIM data collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
