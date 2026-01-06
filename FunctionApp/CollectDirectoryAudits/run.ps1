<#
.SYNOPSIS
    Collects Directory Audit Log data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /auditLogs/directoryAudits for admin/security events
    - Uses time-windowed collection (since last collection timestamp)
    - Focuses on RoleManagement and UserManagement categories
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)

    NOTE: This is EVENT-based data, not entity-based.
    Each run appends new events; no delta detection is used.
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
    Write-Verbose "Starting Directory Audit Logs data collection"

    # Generate ISO 8601 timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Determine time window for collection
    $defaultHoursBack = if ($env:AUDIT_LOGS_HOURS_BACK) { [int]$env:AUDIT_LOGS_HOURS_BACK } else { 24 }
    $sinceDateTime = if ($ActivityInput.LastCollectionTimestamp) {
        [DateTime]$ActivityInput.LastCollectionTimestamp
    } else {
        $now.AddHours(-$defaultHoursBack)
    }
    $sinceFormatted = $sinceDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collecting audits since: $sinceFormatted"

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

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Initialize counters and buffers
    $auditsJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial capacity
    $auditCount = 0
    $batchNumber = 0
    $writeThreshold = 3000

    # Summary statistics by category
    $roleManagementCount = 0
    $userManagementCount = 0
    $groupManagementCount = 0
    $applicationManagementCount = 0
    $otherCount = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-directoryaudits.jsonl"
    Write-Verbose "Initializing append blob: $blobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $blobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query directory audits
    # Note: Requires AuditLog.Read.All permission
    # Filter by time and optionally by category
    $filter = "activityDateTime ge $sinceFormatted"
    $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
    $nextLink = "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=$encodedFilter&`$top=1000"

    Write-Verbose "Starting batch processing with filter: $filter"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $auditBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($auditBatch.Count -eq 0) { break }

        # Process batch
        foreach ($audit in $auditBatch) {
            # Track statistics by category
            $category = $audit.category ?? 'Other'
            switch ($category) {
                'RoleManagement' { $roleManagementCount++ }
                'UserManagement' { $userManagementCount++ }
                'GroupManagement' { $groupManagementCount++ }
                'ApplicationManagement' { $applicationManagementCount++ }
                default { $otherCount++ }
            }

            # Process initiatedBy
            $initiatedBy = @{
                user = @{
                    id = $audit.initiatedBy.user.id ?? ""
                    displayName = $audit.initiatedBy.user.displayName ?? ""
                    userPrincipalName = $audit.initiatedBy.user.userPrincipalName ?? ""
                }
                app = @{
                    appId = $audit.initiatedBy.app.appId ?? ""
                    displayName = $audit.initiatedBy.app.displayName ?? ""
                    servicePrincipalId = $audit.initiatedBy.app.servicePrincipalId ?? ""
                }
            }

            # Process target resources
            $targetResources = @()
            if ($audit.targetResources) {
                foreach ($target in $audit.targetResources) {
                    $targetResources += @{
                        id = $target.id ?? ""
                        displayName = $target.displayName ?? ""
                        type = $target.type ?? ""
                        userPrincipalName = $target.userPrincipalName ?? ""
                        modifiedProperties = $target.modifiedProperties ?? @()
                    }
                }
            }

            # Transform to consistent structure
            $auditObj = @{
                id = $audit.id ?? ""
                activityDateTime = $audit.activityDateTime ?? ""
                activityDisplayName = $audit.activityDisplayName ?? ""
                category = $category
                correlationId = $audit.correlationId ?? ""
                result = $audit.result ?? ""
                resultReason = $audit.resultReason ?? ""
                loggedByService = $audit.loggedByService ?? ""
                operationType = $audit.operationType ?? ""
                initiatedBy = $initiatedBy
                targetResources = $targetResources
                additionalDetails = $audit.additionalDetails ?? @()
                collectionTimestamp = $timestampFormatted
            }

            [void]$auditsJsonL.AppendLine(($auditObj | ConvertTo-Json -Compress -Depth 10))
            $auditCount++
        }

        # Periodic flush to blob
        if ($auditsJsonL.Length -ge ($writeThreshold * 400)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $auditsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($auditsJsonL.Length) characters to blob (batch $batchNumber)"
                $auditsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $auditCount total audits"
    }

    # Final flush
    if ($auditsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $auditsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($auditsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Directory audit logs collection complete: $auditCount audits written to $blobName"

    # Cleanup
    $auditsJsonL.Clear()
    $auditsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'directoryAudits'
        sinceDateTime = $sinceFormatted
        totalCount = $auditCount
        roleManagementCount = $roleManagementCount
        userManagementCount = $userManagementCount
        groupManagementCount = $groupManagementCount
        applicationManagementCount = $applicationManagementCount
        otherCount = $otherCount
        blobPath = $blobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success = $true
        AuditCount = $auditCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-directoryaudits.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
        LastCollectionTimestamp = $timestampFormatted  # For next collection
    }
}
catch {
    Write-Error "Unexpected error in CollectDirectoryAudits: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
