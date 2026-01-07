<#
.SYNOPSIS
    Collects group data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API (beta endpoint for reliable isAssignableToRole)
    - Collects member counts per group (total, users, groups, SPs, devices)
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
#>
#endregion

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

#region Import and Validate
# Validate required environment variables
$requiredEnvVars = @{
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
    'COSMOS_DB_ENDPOINT' = 'Cosmos DB endpoint for indexing'
    'COSMOS_DB_DATABASE' = 'Cosmos DB database name'
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
    Write-Verbose "Starting Entra group data collection"

    # Generate ISO 8601 timestamps (single Get-Date to prevent race condition)
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens (cached - eliminates redundant IMDS calls)
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

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }

    Write-Verbose "Configuration: Batch=$batchSize"

    # Initialize counters and buffers
    $groupsJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $groupCount = 0
    $batchNumber = 0
    $writeThreshold = 5000

    # Summary statistics
    $securityEnabledCount = 0
    $mailEnabledCount = 0
    $m365GroupCount = 0
    $roleAssignableCount = 0
    $cloudOnlyCount = 0
    $syncedCount = 0
    $groupsWithNestedGroupsCount = 0

    # Initialize append blob
    $groupsBlobName = "$timestamp/$timestamp-groups.jsonl"
    Write-Verbose "Initializing append blob: $groupsBlobName"

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $groupsBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Helper function to get member counts for a group
    function Get-GroupMemberCount {
        param(
            [string]$GroupId,
            [string]$AccessToken
        )

        $counts = @{
            memberCountDirect = 0
            userMemberCount = 0
            groupMemberCount = 0
            servicePrincipalMemberCount = 0
            deviceMemberCount = 0
        }

        try {
            # Get members with minimal fields (just need @odata.type for counting)
            $membersUri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id&`$top=999"

            while ($membersUri) {
                $response = Invoke-GraphWithRetry -Uri $membersUri -AccessToken $AccessToken
                foreach ($member in $response.value) {
                    $counts.memberCountDirect++
                    $odataType = $member.'@odata.type'
                    switch ($odataType) {
                        '#microsoft.graph.user' { $counts.userMemberCount++ }
                        '#microsoft.graph.group' { $counts.groupMemberCount++ }
                        '#microsoft.graph.servicePrincipal' { $counts.servicePrincipalMemberCount++ }
                        '#microsoft.graph.device' { $counts.deviceMemberCount++ }
                    }
                }
                $membersUri = $response.'@odata.nextLink'
            }
        }
        catch {
            Write-Warning "Failed to get member counts for group $GroupId`: $_"
        }

        return $counts
    }

    # Query groups with field selection (beta endpoint for isAssignableToRole)
    $selectFields = "displayName,id,classification,deletedDateTime,description,groupTypes,mailEnabled,membershipRule,securityEnabled,isAssignableToRole,createdDateTime,visibility,onPremisesSyncEnabled,onPremisesSecurityIdentifier,mail"
    $nextLink = "https://graph.microsoft.com/beta/groups?`$select=$selectFields&`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes (including member counts)"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $groupBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($groupBatch.Count -eq 0) { break }

        # Sequential process batch
        foreach ($group in $groupBatch) {
            # Get member counts for this group
            $memberCounts = Get-GroupMemberCount -GroupId $group.id -AccessToken $graphToken

            # Transform to consistent camelCase structure with objectId
            $groupObj = @{
                # Core identifiers
                objectId = $group.id ?? ""
                principalType = "group"
                displayName = $group.displayName ?? ""

                # Classification and governance
                classification = $group.classification ?? $null
                deletedDateTime = $group.deletedDateTime ?? $null
                description = $group.description ?? $null

                # Group type and capabilities
                groupTypes = $group.groupTypes ?? @()
                mailEnabled = if ($null -ne $group.mailEnabled) { $group.mailEnabled } else { $null }
                membershipRule = $group.membershipRule ?? $null
                securityEnabled = if ($null -ne $group.securityEnabled) { $group.securityEnabled } else { $null }
                isAssignableToRole = if ($null -ne $group.isAssignableToRole) { $group.isAssignableToRole } else { $null }

                # Metadata
                createdDateTime = $group.createdDateTime ?? $null
                visibility = $group.visibility ?? $null

                # Hybrid identity
                onPremisesSyncEnabled = if ($null -ne $group.onPremisesSyncEnabled) { $group.onPremisesSyncEnabled } else { $null }
                onPremisesSecurityIdentifier = $group.onPremisesSecurityIdentifier ?? $null

                # Communication
                mail = $group.mail ?? $null

                # Member statistics
                memberCountDirect = $memberCounts.memberCountDirect
                userMemberCount = $memberCounts.userMemberCount
                groupMemberCount = $memberCounts.groupMemberCount
                servicePrincipalMemberCount = $memberCounts.servicePrincipalMemberCount
                deviceMemberCount = $memberCounts.deviceMemberCount

                # Locally-generated property (collection metadata)
                collectionTimestamp = $timestampFormatted
            }

            [void]$groupsJsonL.AppendLine(($groupObj | ConvertTo-Json -Compress))
            $groupCount++

            # Track summary statistics
            if ($groupObj.securityEnabled -eq $true) { $securityEnabledCount++ }
            if ($groupObj.mailEnabled -eq $true) { $mailEnabledCount++ }
            if ($groupObj.groupTypes -contains "Unified") { $m365GroupCount++ }
            if ($groupObj.isAssignableToRole -eq $true) { $roleAssignableCount++ }
            if ($groupObj.onPremisesSyncEnabled -eq $true) { $syncedCount++ } else { $cloudOnlyCount++ }
            if ($groupObj.groupMemberCount -gt 0) { $groupsWithNestedGroupsCount++ }
        }

        # Periodic flush to blob (every ~5000 groups)
        if ($groupsJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $groupsBlobName `
                                -Content $groupsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($groupsJsonL.Length) characters to blob (batch $batchNumber)"
                $groupsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $groupCount total groups"
    }

    # Final flush
    if ($groupsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $groupsBlobName `
                            -Content $groupsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($groupsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Group collection complete: $groupCount groups written to $groupsBlobName"

    # Cleanup
    $groupsJsonL.Clear()
    $groupsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'groups'
        totalCount = $groupCount
        securityEnabledCount = $securityEnabledCount
        mailEnabledCount = $mailEnabledCount
        m365GroupCount = $m365GroupCount
        roleAssignableCount = $roleAssignableCount
        cloudOnlyCount = $cloudOnlyCount
        syncedCount = $syncedCount
        groupsWithNestedGroupsCount = $groupsWithNestedGroupsCount
        blobPath = $groupsBlobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success = $true
        GroupCount = $groupCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-groups.jsonl"
        Timestamp = $timestamp
        BlobName = $groupsBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectEntraGroups: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
