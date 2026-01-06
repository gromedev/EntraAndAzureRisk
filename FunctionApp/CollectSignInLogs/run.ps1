<#
.SYNOPSIS
    Collects Sign-In Log data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /auditLogs/signIns for failed and risky sign-ins
    - Uses time-windowed collection (since last collection timestamp)
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
    Write-Verbose "Starting Sign-In Logs data collection"

    # Generate ISO 8601 timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Determine time window for collection
    # Use lastCollectionTimestamp from input if provided, otherwise default to 24 hours ago
    $defaultHoursBack = if ($env:SIGNIN_LOGS_HOURS_BACK) { [int]$env:SIGNIN_LOGS_HOURS_BACK } else { 24 }
    $sinceDateTime = if ($ActivityInput.LastCollectionTimestamp) {
        [DateTime]$ActivityInput.LastCollectionTimestamp
    } else {
        $now.AddHours(-$defaultHoursBack)
    }
    $sinceFormatted = $sinceDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collecting sign-ins since: $sinceFormatted"

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
    $signInsJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial capacity
    $signInCount = 0
    $batchNumber = 0
    $writeThreshold = 3000

    # Summary statistics
    $failedCount = 0
    $riskyCount = 0
    $mfaFailedCount = 0
    $interactiveCount = 0
    $nonInteractiveCount = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-signinlogs.jsonl"
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

    # Query sign-in logs with filter for failed/risky only
    # Note: Requires AuditLog.Read.All permission
    # Filter: failed sign-ins (errorCode != 0) OR risky sign-ins (riskLevelAggregated != none)
    $filter = "createdDateTime ge $sinceFormatted and (status/errorCode ne 0 or riskLevelAggregated ne 'none')"
    $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
    $nextLink = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$encodedFilter&`$top=1000"

    Write-Verbose "Starting batch processing with filter: $filter"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $signInBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($signInBatch.Count -eq 0) { break }

        # Process batch
        foreach ($signIn in $signInBatch) {
            # Extract status info
            $errorCode = $signIn.status.errorCode ?? 0
            $failureReason = $signIn.status.failureReason ?? ""

            # Track statistics
            if ($errorCode -ne 0) {
                $failedCount++
                # Check for MFA-related failures
                if ($failureReason -match 'MFA|multi-factor|50076|50074|50079') {
                    $mfaFailedCount++
                }
            }

            $riskLevel = $signIn.riskLevelAggregated ?? 'none'
            if ($riskLevel -ne 'none') {
                $riskyCount++
            }

            if ($signIn.isInteractive -eq $true) {
                $interactiveCount++
            } else {
                $nonInteractiveCount++
            }

            # Transform to consistent structure
            $signInObj = @{
                id = $signIn.id ?? ""
                createdDateTime = $signIn.createdDateTime ?? ""
                userDisplayName = $signIn.userDisplayName ?? ""
                userPrincipalName = $signIn.userPrincipalName ?? ""
                userId = $signIn.userId ?? ""
                appId = $signIn.appId ?? ""
                appDisplayName = $signIn.appDisplayName ?? ""
                ipAddress = $signIn.ipAddress ?? ""
                clientAppUsed = $signIn.clientAppUsed ?? ""
                isInteractive = if ($null -ne $signIn.isInteractive) { $signIn.isInteractive } else { $null }
                # Status
                errorCode = $errorCode
                failureReason = $failureReason
                additionalDetails = $signIn.status.additionalDetails ?? ""
                # Risk
                riskLevelAggregated = $riskLevel
                riskLevelDuringSignIn = $signIn.riskLevelDuringSignIn ?? 'none'
                riskState = $signIn.riskState ?? ""
                riskDetail = $signIn.riskDetail ?? ""
                # Conditional Access
                conditionalAccessStatus = $signIn.conditionalAccessStatus ?? ""
                appliedConditionalAccessPolicies = $signIn.appliedConditionalAccessPolicies ?? @()
                # Location
                location = @{
                    city = $signIn.location.city ?? ""
                    state = $signIn.location.state ?? ""
                    countryOrRegion = $signIn.location.countryOrRegion ?? ""
                }
                # Device
                deviceDetail = @{
                    deviceId = $signIn.deviceDetail.deviceId ?? ""
                    displayName = $signIn.deviceDetail.displayName ?? ""
                    operatingSystem = $signIn.deviceDetail.operatingSystem ?? ""
                    browser = $signIn.deviceDetail.browser ?? ""
                    isCompliant = $signIn.deviceDetail.isCompliant ?? $null
                    isManaged = $signIn.deviceDetail.isManaged ?? $null
                    trustType = $signIn.deviceDetail.trustType ?? ""
                }
                # Resource
                resourceDisplayName = $signIn.resourceDisplayName ?? ""
                resourceId = $signIn.resourceId ?? ""
                # Metadata
                collectionTimestamp = $timestampFormatted
            }

            [void]$signInsJsonL.AppendLine(($signInObj | ConvertTo-Json -Compress -Depth 10))
            $signInCount++
        }

        # Periodic flush to blob
        if ($signInsJsonL.Length -ge ($writeThreshold * 400)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $signInsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($signInsJsonL.Length) characters to blob (batch $batchNumber)"
                $signInsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $signInCount total sign-ins"
    }

    # Final flush
    if ($signInsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $signInsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($signInsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Sign-in logs collection complete: $signInCount sign-ins written to $blobName"

    # Cleanup
    $signInsJsonL.Clear()
    $signInsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'signInLogs'
        sinceDateTime = $sinceFormatted
        totalCount = $signInCount
        failedCount = $failedCount
        riskyCount = $riskyCount
        mfaFailedCount = $mfaFailedCount
        interactiveCount = $interactiveCount
        nonInteractiveCount = $nonInteractiveCount
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
        SignInCount = $signInCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-signinlogs.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
        LastCollectionTimestamp = $timestampFormatted  # For next collection
    }
}
catch {
    Write-Error "Unexpected error in CollectSignInLogs: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
