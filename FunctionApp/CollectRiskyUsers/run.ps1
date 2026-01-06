<#
.SYNOPSIS
    Collects risky user data from Microsoft Entra ID Identity Protection and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /identityProtection/riskyUsers with pagination
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
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
    Write-Verbose "Starting Entra risky user data collection"

    # Generate ISO 8601 timestamps
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

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 500 }  # Max 500 for risky users

    Write-Verbose "Configuration: Batch=$batchSize"

    # Initialize counters and buffers
    $riskyUsersJsonL = New-Object System.Text.StringBuilder(524288)  # 512KB initial capacity
    $riskyUserCount = 0
    $batchNumber = 0
    $writeThreshold = 2500

    # Summary statistics by risk level
    $highRiskCount = 0
    $mediumRiskCount = 0
    $lowRiskCount = 0
    $noneRiskCount = 0

    # Summary statistics by risk state
    $atRiskCount = 0
    $confirmedCompromisedCount = 0
    $remediatedCount = 0
    $dismissedCount = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-riskyusers.jsonl"
    Write-Verbose "Initializing append blob: $blobName"

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

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

    # Query risky users - API endpoint
    # Note: Requires IdentityRiskyUser.Read.All permission
    $nextLink = "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $riskyUserBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Error "Failed to retrieve batch $batchNumber`: $errorMessage"

            # Check for permission/auth errors that won't be resolved by retry
            if ($errorMessage -match "Forbidden|403|scopes are missing|Unauthorized|401") {
                Write-Warning "Permission error detected - returning empty collection"
                return @{
                    Success = $true
                    RiskyUserCount = 0
                    Data = @()
                    Summary = @{
                        id = $timestamp
                        collectionTimestamp = $timestampFormatted
                        collectionType = 'riskyUsers'
                        totalCount = 0
                        error = "Permission denied - requires IdentityRiskyUser.Read.All with admin consent"
                    }
                    FileName = "$timestamp-riskyusers.jsonl"
                    Timestamp = $timestamp
                    BlobName = $blobName
                }
            }

            # For other errors, break out of loop to avoid infinite retry
            Write-Warning "Breaking out of batch loop due to unrecoverable error"
            break
        }

        if ($riskyUserBatch.Count -eq 0) { break }

        # Process batch
        foreach ($riskyUser in $riskyUserBatch) {
            # Transform to consistent structure with objectId
            $riskyUserObj = @{
                objectId = $riskyUser.id ?? ""
                userPrincipalName = $riskyUser.userPrincipalName ?? ""
                userDisplayName = $riskyUser.userDisplayName ?? ""
                riskLevel = $riskyUser.riskLevel ?? "none"
                riskState = $riskyUser.riskState ?? ""
                riskDetail = $riskyUser.riskDetail ?? ""
                riskLastUpdatedDateTime = $riskyUser.riskLastUpdatedDateTime ?? $null
                isDeleted = if ($null -ne $riskyUser.isDeleted) { $riskyUser.isDeleted } else { $false }
                isProcessing = if ($null -ne $riskyUser.isProcessing) { $riskyUser.isProcessing } else { $false }
                collectionTimestamp = $timestampFormatted
            }

            [void]$riskyUsersJsonL.AppendLine(($riskyUserObj | ConvertTo-Json -Compress))
            $riskyUserCount++

            # Track statistics by risk level
            switch ($riskyUserObj.riskLevel) {
                'high' { $highRiskCount++ }
                'medium' { $mediumRiskCount++ }
                'low' { $lowRiskCount++ }
                'none' { $noneRiskCount++ }
            }

            # Track statistics by risk state
            switch ($riskyUserObj.riskState) {
                'atRisk' { $atRiskCount++ }
                'confirmedCompromised' { $confirmedCompromisedCount++ }
                'remediated' { $remediatedCount++ }
                'dismissed' { $dismissedCount++ }
            }
        }

        # Periodic flush to blob
        if ($riskyUsersJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $riskyUsersJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($riskyUsersJsonL.Length) characters to blob (batch $batchNumber)"
                $riskyUsersJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $riskyUserCount total risky users"
    }

    # Final flush
    if ($riskyUsersJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $riskyUsersJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($riskyUsersJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Risky user collection complete: $riskyUserCount risky users written to $blobName"

    # Cleanup
    $riskyUsersJsonL.Clear()
    $riskyUsersJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'riskyUsers'
        totalCount = $riskyUserCount
        highRiskCount = $highRiskCount
        mediumRiskCount = $mediumRiskCount
        lowRiskCount = $lowRiskCount
        noneRiskCount = $noneRiskCount
        atRiskCount = $atRiskCount
        confirmedCompromisedCount = $confirmedCompromisedCount
        remediatedCount = $remediatedCount
        dismissedCount = $dismissedCount
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
        RiskyUserCount = $riskyUserCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-riskyusers.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
    }
}
catch {
    Write-Error "Unexpected error in CollectRiskyUsers: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
