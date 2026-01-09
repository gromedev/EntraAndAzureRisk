<#
.SYNOPSIS
    Collects Administrative Units and their memberships
.DESCRIPTION
    Administrative Units (AUs) are organizational containers used to delegate
    admin permissions for a subset of users, groups, and devices.

    APIs:
    - /v1.0/directory/administrativeUnits - List all AUs
    - /v1.0/directory/administrativeUnits/{id}/members - AU members

    Output:
    - principals.jsonl (principalType = "administrativeUnit")
    - edges.jsonl (edgeType = "auMember")

    Permission: AdministrativeUnit.Read.All
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
        MembersPerAU = @{}
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

        foreach ($au in $aus) {
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
                deleted = $false
                collectionTimestamp = $timestampFormatted
            }

            [void]$principalsJsonL.AppendLine(($auObj | ConvertTo-Json -Compress -Depth 10))
            $stats.TotalAUs++

            # Collect AU members
            $membersNextLink = "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($au.id)/members"
            $memberCount = 0

            while ($membersNextLink) {
                try {
                    $membersResponse = Invoke-GraphWithRetry -Uri $membersNextLink -AccessToken $graphToken
                    $members = $membersResponse.value
                    $membersNextLink = $membersResponse.'@odata.nextLink'
                }
                catch {
                    Write-Warning "Failed to get members for AU $($au.displayName): $_"
                    break
                }

                if ($members.Count -eq 0) { break }

                foreach ($member in $members) {
                    $odataType = $member.'@odata.type' -replace '#microsoft.graph.', ''
                    $memberType = switch ($odataType) {
                        'user' { 'user' }
                        'group' { 'group' }
                        'device' { 'device' }
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
            }

            $stats.MembersPerAU[$au.displayName] = $memberCount
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

    Write-Verbose "Administrative Units collection complete: $($stats.TotalAUs) AUs, $($stats.TotalMembers) memberships"

    return @{
        Success = $true
        AUCount = $stats.TotalAUs
        MembershipCount = $stats.TotalMembers
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
