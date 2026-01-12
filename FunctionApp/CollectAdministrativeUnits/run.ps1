<#
.SYNOPSIS
    Collects Administrative Units, their memberships, and scoped role assignments
.DESCRIPTION
    Administrative Units (AUs) are organizational containers used to delegate
    admin permissions for a subset of users, groups, and devices.

    APIs:
    - /v1.0/directory/administrativeUnits - List all AUs
    - /v1.0/directory/administrativeUnits/{id}/members - AU members
    - /v1.0/directory/administrativeUnits/{id}/scopedRoleMembers - Delegated role assignments

    Output:
    - principals.jsonl (principalType = "administrativeUnit")
    - edges.jsonl (edgeType = "auMember", "auScopedRole")

    Permission: AdministrativeUnit.Read.All, RoleManagement.Read.Directory
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    return @{ Success = $false; Error = "Failed to import module: $($_.Exception.Message)" }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Administrative Units collection"

    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get tokens
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        return @{ Success = $false; Error = "Token acquisition failed: $($_.Exception.Message)" }
    }

    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Initialize buffers
    $principalsJsonL = New-Object System.Text.StringBuilder(1048576)
    $edgesJsonL = New-Object System.Text.StringBuilder(1048576)

    $stats = @{
        TotalAUs = 0
        TotalMembers = 0
        TotalScopedRoles = 0
        UserMemberCount = 0
        GroupMemberCount = 0
        DeviceMemberCount = 0
        MembersPerAU = @{}
        ScopedRolesPerAU = @{}
    }

    # Build directory role template lookup for human-friendly names
    $roleTemplateLookup = @{}
    try {
        Write-Verbose "Building directory role template lookup..."
        $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
        $rolesResponse = Invoke-GraphWithRetry -Uri $rolesUri -AccessToken $graphToken
        foreach ($role in $rolesResponse.value) {
            $roleTemplateLookup[$role.id] = $role.displayName
        }
        Write-Verbose "Loaded $($roleTemplateLookup.Count) role templates"
    }
    catch {
        Write-Warning "Failed to load role template lookup: $_ - scoped role names may show as GUIDs"
    }

    # Initialize blobs
    $principalsBlobName = "$timestamp/$timestamp-principals.jsonl"
    $edgesBlobName = "$timestamp/$timestamp-edges.jsonl"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $principalsBlobName `
                              -AccessToken $storageToken
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $edgesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        if ($_.Exception.Message -notmatch '409|ContainerAlreadyExists|BlobAlreadyExists') {
            return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
        }
    }

    # Collect Administrative Units
    Write-Verbose "Collecting Administrative Units..."
    $auNextLink = "https://graph.microsoft.com/v1.0/directory/administrativeUnits"

    while ($auNextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $auNextLink -AccessToken $graphToken
            $aus = $response.value
            $auNextLink = $response.'@odata.nextLink'
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Administrative Units requires AdministrativeUnit.Read.All permission"
            } else {
                Write-Warning "Failed to retrieve Administrative Units: $_"
            }
            break
        }

        if ($aus.Count -eq 0) { break }

        # --- BATCH: Get members and scopedRoleMembers for all AUs in this batch ---
        $membersBatchRequests = @($aus | ForEach-Object {
            @{
                id = $_.id
                method = "GET"
                url = "/directory/administrativeUnits/$($_.id)/members"
            }
        })
        $scopedRolesBatchRequests = @($aus | ForEach-Object {
            @{
                id = $_.id
                method = "GET"
                url = "/directory/administrativeUnits/$($_.id)/scopedRoleMembers"
            }
        })

        # Execute batch requests
        $membersBatchResponses = Invoke-GraphBatch -Requests $membersBatchRequests -AccessToken $graphToken
        $scopedRolesBatchResponses = Invoke-GraphBatch -Requests $scopedRolesBatchRequests -AccessToken $graphToken

        foreach ($au in $aus) {
            # Track member counts per AU
            $auUserCount = 0
            $auGroupCount = 0
            $auDeviceCount = 0
            $auScopedRoleCount = 0
            $memberCount = 0

            # Get members from batch result
            $membersResponse = $membersBatchResponses[$au.id]
            if ($null -ne $membersResponse -and $membersResponse.value) {
                foreach ($member in $membersResponse.value) {
                    $odataType = $member.'@odata.type' -replace '#microsoft.graph.', ''
                    $memberType = switch ($odataType) {
                        'user' { $auUserCount++; $stats.UserMemberCount++; 'user' }
                        'group' { $auGroupCount++; $stats.GroupMemberCount++; 'group' }
                        'device' { $auDeviceCount++; $stats.DeviceMemberCount++; 'device' }
                        default { $odataType }
                    }

                    $edgeObj = @{
                        objectId = "$($member.id)_$($au.id)_auMember"
                        edgeType = "auMember"
                        sourceId = $member.id
                        sourceType = $memberType
                        sourceDisplayName = $member.displayName ?? ""
                        targetId = $au.id
                        targetType = "administrativeUnit"
                        targetDisplayName = $au.displayName ?? ""
                        deleted = $false
                        collectionTimestamp = $timestampFormatted
                    }

                    # Add source-specific fields
                    if ($memberType -eq 'user') {
                        $edgeObj.sourceUserPrincipalName = $member.userPrincipalName ?? $null
                        $edgeObj.sourceAccountEnabled = $member.accountEnabled ?? $null
                    }

                    [void]$edgesJsonL.AppendLine(($edgeObj | ConvertTo-Json -Compress -Depth 10))
                    $memberCount++
                    $stats.TotalMembers++
                }

                # Handle pagination for AUs with many members (follow nextLink if present)
                $membersNextLink = $membersResponse.'@odata.nextLink'
                while ($membersNextLink) {
                    try {
                        $moreMembers = Invoke-GraphWithRetry -Uri $membersNextLink -AccessToken $graphToken
                        $membersNextLink = $moreMembers.'@odata.nextLink'

                        foreach ($member in $moreMembers.value) {
                            $odataType = $member.'@odata.type' -replace '#microsoft.graph.', ''
                            $memberType = switch ($odataType) {
                                'user' { $auUserCount++; $stats.UserMemberCount++; 'user' }
                                'group' { $auGroupCount++; $stats.GroupMemberCount++; 'group' }
                                'device' { $auDeviceCount++; $stats.DeviceMemberCount++; 'device' }
                                default { $odataType }
                            }

                            $edgeObj = @{
                                objectId = "$($member.id)_$($au.id)_auMember"
                                edgeType = "auMember"
                                sourceId = $member.id
                                sourceType = $memberType
                                sourceDisplayName = $member.displayName ?? ""
                                targetId = $au.id
                                targetType = "administrativeUnit"
                                targetDisplayName = $au.displayName ?? ""
                                deleted = $false
                                collectionTimestamp = $timestampFormatted
                            }

                            if ($memberType -eq 'user') {
                                $edgeObj.sourceUserPrincipalName = $member.userPrincipalName ?? $null
                                $edgeObj.sourceAccountEnabled = $member.accountEnabled ?? $null
                            }

                            [void]$edgesJsonL.AppendLine(($edgeObj | ConvertTo-Json -Compress -Depth 10))
                            $memberCount++
                            $stats.TotalMembers++
                        }
                    }
                    catch {
                        Write-Warning "Failed to get additional members for AU $($au.displayName): $_"
                        break
                    }
                }
            }

            $stats.MembersPerAU[$au.displayName] = $memberCount

            # Get scoped role members from batch result
            $scopedRoles = @()
            $scopedResponse = $scopedRolesBatchResponses[$au.id]
            if ($null -ne $scopedResponse -and $scopedResponse.value) {
                $scopedRoles = $scopedResponse.value

                # Handle pagination for AUs with many scoped roles
                $scopedRolesNextLink = $scopedResponse.'@odata.nextLink'
                while ($scopedRolesNextLink) {
                    try {
                        $moreScopedRoles = Invoke-GraphWithRetry -Uri $scopedRolesNextLink -AccessToken $graphToken
                        $scopedRoles += $moreScopedRoles.value
                        $scopedRolesNextLink = $moreScopedRoles.'@odata.nextLink'
                    }
                    catch {
                        Write-Warning "Failed to get additional scoped roles for AU $($au.displayName): $_"
                        break
                    }
                }
            }

            # Create edges for scoped role assignments
            foreach ($scopedRole in $scopedRoles) {
                $roleId = $scopedRole.roleId
                $roleName = if ($roleTemplateLookup.ContainsKey($roleId)) { $roleTemplateLookup[$roleId] } else { $roleId }
                $principalId = $scopedRole.roleMemberInfo.id
                $principalDisplayName = $scopedRole.roleMemberInfo.displayName ?? ""

                $scopedEdgeObj = @{
                    objectId = "$($principalId)_$($au.id)_$($roleId)_auScopedRole"
                    edgeType = "auScopedRole"
                    sourceId = $principalId
                    sourceType = "user"  # Scoped role assignments are typically to users
                    sourceDisplayName = $principalDisplayName
                    targetId = $au.id
                    targetType = "administrativeUnit"
                    targetDisplayName = $au.displayName ?? ""
                    roleId = $roleId
                    roleName = $roleName
                    deleted = $false
                    collectionTimestamp = $timestampFormatted
                }

                [void]$edgesJsonL.AppendLine(($scopedEdgeObj | ConvertTo-Json -Compress -Depth 10))
                $auScopedRoleCount++
                $stats.TotalScopedRoles++
            }

            $stats.ScopedRolesPerAU[$au.displayName] = $auScopedRoleCount

            # Build the AU object with member counts
            $auObj = @{
                objectId = $au.id
                principalType = "administrativeUnit"
                displayName = $au.displayName ?? ""
                description = $au.description ?? ""
                membershipType = $au.membershipType ?? "Assigned"
                membershipRule = $au.membershipRule ?? $null
                membershipRuleProcessingState = $au.membershipRuleProcessingState ?? $null
                isMemberManagementRestricted = $au.isMemberManagementRestricted ?? $false
                visibility = $au.visibility ?? $null
                # Member counts
                memberCountTotal = $memberCount
                userMemberCount = $auUserCount
                groupMemberCount = $auGroupCount
                deviceMemberCount = $auDeviceCount
                # Scoped role count
                scopedRoleCount = $auScopedRoleCount
                deleted = $false
                collectionTimestamp = $timestampFormatted
            }

            [void]$principalsJsonL.AppendLine(($auObj | ConvertTo-Json -Compress -Depth 10))
            $stats.TotalAUs++
        }
    }

    # Flush to blobs
    if ($principalsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $principalsBlobName `
                            -Content $principalsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
        }
        catch {
            Write-Warning "Failed to write principals: $_"
        }
    }

    if ($edgesJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $edgesBlobName `
                            -Content $edgesJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
        }
        catch {
            Write-Warning "Failed to write edges: $_"
        }
    }

    Write-Verbose "Administrative Units collection complete: $($stats.TotalAUs) AUs, $($stats.TotalMembers) memberships, $($stats.TotalScopedRoles) scoped roles"

    return @{
        Success = $true
        AUCount = $stats.TotalAUs
        MembershipCount = $stats.TotalMembers
        ScopedRoleCount = $stats.TotalScopedRoles
        UserMemberCount = $stats.UserMemberCount
        GroupMemberCount = $stats.GroupMemberCount
        DeviceMemberCount = $stats.DeviceMemberCount
        Statistics = $stats
        BlobName = $principalsBlobName
        EdgesBlobName = $edgesBlobName
        Timestamp = $timestamp
    }
}
catch {
    Write-Error "CollectAdministrativeUnits failed: $_"
    return @{ Success = $false; Error = $_.Exception.Message }
}
#endregion
