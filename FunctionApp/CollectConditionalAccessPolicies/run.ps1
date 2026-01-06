<#
.SYNOPSIS
    Collects Conditional Access policy data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /identity/conditionalAccess/policies with pagination
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
    Write-Verbose "Starting Conditional Access policy data collection"

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
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 100 }  # CA policies are typically fewer

    Write-Verbose "Configuration: Batch=$batchSize"

    # Initialize counters and buffers
    $policiesJsonL = New-Object System.Text.StringBuilder(524288)  # 512KB initial capacity
    $policyCount = 0
    $batchNumber = 0
    $writeThreshold = 1000

    # Summary statistics by state
    $enabledCount = 0
    $disabledCount = 0
    $reportOnlyCount = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-capolicies.jsonl"
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

    # Query Conditional Access policies
    # Note: Requires Policy.Read.All permission
    $nextLink = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $policyBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($policyBatch.Count -eq 0) { break }

        # Process batch
        foreach ($policy in $policyBatch) {
            # Transform to consistent structure with objectId
            $policyObj = @{
                objectId = $policy.id ?? ""
                displayName = $policy.displayName ?? ""
                state = $policy.state ?? ""
                createdDateTime = $policy.createdDateTime ?? $null
                modifiedDateTime = $policy.modifiedDateTime ?? $null
                # Conditions - store as nested object
                conditions = @{
                    users = $policy.conditions.users ?? @{}
                    applications = $policy.conditions.applications ?? @{}
                    clientAppTypes = $policy.conditions.clientAppTypes ?? @()
                    platforms = $policy.conditions.platforms ?? @{}
                    locations = $policy.conditions.locations ?? @{}
                    signInRiskLevels = $policy.conditions.signInRiskLevels ?? @()
                    userRiskLevels = $policy.conditions.userRiskLevels ?? @()
                }
                # Grant controls
                grantControls = @{
                    operator = $policy.grantControls.operator ?? ""
                    builtInControls = $policy.grantControls.builtInControls ?? @()
                    customAuthenticationFactors = $policy.grantControls.customAuthenticationFactors ?? @()
                    termsOfUse = $policy.grantControls.termsOfUse ?? @()
                }
                # Session controls
                sessionControls = @{
                    applicationEnforcedRestrictions = $policy.sessionControls.applicationEnforcedRestrictions ?? $null
                    cloudAppSecurity = $policy.sessionControls.cloudAppSecurity ?? $null
                    persistentBrowser = $policy.sessionControls.persistentBrowser ?? $null
                    signInFrequency = $policy.sessionControls.signInFrequency ?? $null
                }
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $policyCount++

            # Track statistics by state
            switch ($policyObj.state) {
                'enabled' { $enabledCount++ }
                'disabled' { $disabledCount++ }
                'enabledForReportingButNotEnforced' { $reportOnlyCount++ }
            }
        }

        # Periodic flush to blob
        if ($policiesJsonL.Length -ge ($writeThreshold * 500)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $policiesJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($policiesJsonL.Length) characters to blob (batch $batchNumber)"
                $policiesJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $policyCount total policies"
    }

    # Final flush
    if ($policiesJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $policiesJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($policiesJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Conditional Access policy collection complete: $policyCount policies written to $blobName"

    # Cleanup
    $policiesJsonL.Clear()
    $policiesJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'conditionalAccessPolicies'
        totalCount = $policyCount
        enabledCount = $enabledCount
        disabledCount = $disabledCount
        reportOnlyCount = $reportOnlyCount
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
        PolicyCount = $policyCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-capolicies.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
    }
}
catch {
    Write-Error "Unexpected error in CollectConditionalAccessPolicies: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
