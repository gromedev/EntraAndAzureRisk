<#
.SYNOPSIS
    Collects App Registration data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /applications with pagination
    - Includes keyCredentials (certificates) and passwordCredentials (secrets)
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
    Write-Verbose "Starting App Registration data collection"

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
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }

    Write-Verbose "Configuration: Batch=$batchSize"

    # Initialize counters and buffers
    $appsJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $appCount = 0
    $batchNumber = 0
    $writeThreshold = 3000

    # Summary statistics for credentials
    $appsWithSecretsCount = 0
    $appsWithCertificatesCount = 0
    $expiredSecretsCount = 0
    $expiredCertificatesCount = 0
    $expiringSecretsCount = 0  # Within 30 days
    $expiringCertificatesCount = 0  # Within 30 days
    $appsWithFederatedCredentialsCount = 0
    $appsWithVerifiedPublisherCount = 0
    $appsWithApiPermissionsCount = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-appregistrations.jsonl"
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

    # Query applications with keyCredentials and passwordCredentials
    # Note: Requires Application.Read.All permission
    # Note: There's a throttling limit of 150 requests per minute for keyCredentials
    # Added: requiredResourceAccess (API permissions), verifiedPublisher
    $selectFields = "id,appId,displayName,createdDateTime,signInAudience,publisherDomain,keyCredentials,passwordCredentials,requiredResourceAccess,verifiedPublisher"
    $nextLink = "https://graph.microsoft.com/v1.0/applications?`$select=$selectFields&`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes"

    # Calculate dates for expiry checks
    $nowDate = (Get-Date).ToUniversalTime()
    $thirtyDaysFromNow = $nowDate.AddDays(30)

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $appBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($appBatch.Count -eq 0) { break }

        # Process batch
        foreach ($app in $appBatch) {
            # Process credentials
            $hasSecrets = $false
            $hasCertificates = $false
            $processedSecrets = @()
            $processedCertificates = @()

            # Process password credentials (secrets)
            if ($app.passwordCredentials -and $app.passwordCredentials.Count -gt 0) {
                $hasSecrets = $true
                foreach ($secret in $app.passwordCredentials) {
                    $endDateTime = if ($secret.endDateTime) { [DateTime]$secret.endDateTime } else { $null }
                    $status = 'active'

                    if ($endDateTime) {
                        if ($endDateTime -lt $nowDate) {
                            $status = 'expired'
                            $expiredSecretsCount++
                        } elseif ($endDateTime -lt $thirtyDaysFromNow) {
                            $status = 'expiring_soon'
                            $expiringSecretsCount++
                        }
                    }

                    $processedSecrets += @{
                        keyId = $secret.keyId ?? ""
                        displayName = $secret.displayName ?? ""
                        startDateTime = $secret.startDateTime ?? $null
                        endDateTime = $secret.endDateTime ?? $null
                        status = $status
                    }
                }
            }

            # Process key credentials (certificates)
            if ($app.keyCredentials -and $app.keyCredentials.Count -gt 0) {
                $hasCertificates = $true
                foreach ($cert in $app.keyCredentials) {
                    $endDateTime = if ($cert.endDateTime) { [DateTime]$cert.endDateTime } else { $null }
                    $status = 'active'

                    if ($endDateTime) {
                        if ($endDateTime -lt $nowDate) {
                            $status = 'expired'
                            $expiredCertificatesCount++
                        } elseif ($endDateTime -lt $thirtyDaysFromNow) {
                            $status = 'expiring_soon'
                            $expiringCertificatesCount++
                        }
                    }

                    $processedCertificates += @{
                        keyId = $cert.keyId ?? ""
                        displayName = $cert.displayName ?? ""
                        type = $cert.type ?? ""
                        usage = $cert.usage ?? ""
                        startDateTime = $cert.startDateTime ?? $null
                        endDateTime = $cert.endDateTime ?? $null
                        status = $status
                    }
                }
            }

            if ($hasSecrets) { $appsWithSecretsCount++ }
            if ($hasCertificates) { $appsWithCertificatesCount++ }

            # Process requiredResourceAccess (API permissions requested)
            $processedApiPermissions = @()
            if ($app.requiredResourceAccess -and $app.requiredResourceAccess.Count -gt 0) {
                $appsWithApiPermissionsCount++
                foreach ($resource in $app.requiredResourceAccess) {
                    $resourceAccess = @{
                        resourceAppId = $resource.resourceAppId ?? ""
                        resourceAccess = @($resource.resourceAccess | ForEach-Object {
                            @{
                                id = $_.id ?? ""
                                type = $_.type ?? ""  # "Role" = Application, "Scope" = Delegated
                            }
                        })
                    }
                    $processedApiPermissions += $resourceAccess
                }
            }

            # Process verifiedPublisher
            $verifiedPublisher = $null
            if ($app.verifiedPublisher -and $app.verifiedPublisher.displayName) {
                $appsWithVerifiedPublisherCount++
                $verifiedPublisher = @{
                    displayName = $app.verifiedPublisher.displayName ?? ""
                    verifiedPublisherId = $app.verifiedPublisher.verifiedPublisherId ?? ""
                    addedDateTime = $app.verifiedPublisher.addedDateTime ?? $null
                }
            }

            # Get federated identity credentials (separate API call)
            $federatedCredentials = @()
            $hasFederatedCredentials = $false
            try {
                $fedCredsUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)/federatedIdentityCredentials"
                $fedCredsResponse = Invoke-GraphWithRetry -Uri $fedCredsUri -AccessToken $graphToken
                if ($fedCredsResponse.value -and $fedCredsResponse.value.Count -gt 0) {
                    $hasFederatedCredentials = $true
                    $appsWithFederatedCredentialsCount++
                    foreach ($fedCred in $fedCredsResponse.value) {
                        $federatedCredentials += @{
                            id = $fedCred.id ?? ""
                            name = $fedCred.name ?? ""
                            issuer = $fedCred.issuer ?? ""
                            subject = $fedCred.subject ?? ""
                            audiences = $fedCred.audiences ?? @()
                            description = $fedCred.description ?? ""
                        }
                    }
                }
            }
            catch {
                Write-Warning "Failed to get federated credentials for app $($app.displayName): $_"
            }

            # Transform to consistent structure with objectId
            $appObj = @{
                objectId = $app.id ?? ""
                principalType = "application"
                appId = $app.appId ?? ""
                displayName = $app.displayName ?? ""
                createdDateTime = $app.createdDateTime ?? ""
                signInAudience = $app.signInAudience ?? ""
                publisherDomain = $app.publisherDomain ?? ""
                passwordCredentials = $processedSecrets
                keyCredentials = $processedCertificates
                secretCount = $processedSecrets.Count
                certificateCount = $processedCertificates.Count
                requiredResourceAccess = $processedApiPermissions
                apiPermissionCount = ($processedApiPermissions | ForEach-Object { $_.resourceAccess.Count } | Measure-Object -Sum).Sum
                verifiedPublisher = $verifiedPublisher
                isPublisherVerified = ($null -ne $verifiedPublisher)
                federatedIdentityCredentials = $federatedCredentials
                hasFederatedCredentials = $hasFederatedCredentials
                federatedCredentialCount = $federatedCredentials.Count
                collectionTimestamp = $timestampFormatted
            }

            [void]$appsJsonL.AppendLine(($appObj | ConvertTo-Json -Compress -Depth 10))
            $appCount++
        }

        # Periodic flush to blob
        if ($appsJsonL.Length -ge ($writeThreshold * 300)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $appsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($appsJsonL.Length) characters to blob (batch $batchNumber)"
                $appsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $appCount total apps"
    }

    # Final flush
    if ($appsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $appsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($appsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "App Registration collection complete: $appCount apps written to $blobName"

    # Cleanup
    $appsJsonL.Clear()
    $appsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'appRegistrations'
        totalCount = $appCount
        appsWithSecretsCount = $appsWithSecretsCount
        appsWithCertificatesCount = $appsWithCertificatesCount
        expiredSecretsCount = $expiredSecretsCount
        expiredCertificatesCount = $expiredCertificatesCount
        expiringSecretsCount = $expiringSecretsCount
        expiringCertificatesCount = $expiringCertificatesCount
        appsWithFederatedCredentialsCount = $appsWithFederatedCredentialsCount
        appsWithVerifiedPublisherCount = $appsWithVerifiedPublisherCount
        appsWithApiPermissionsCount = $appsWithApiPermissionsCount
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
        AppCount = $appCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-appregistrations.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
    }
}
catch {
    Write-Error "Unexpected error in CollectAppRegistrations: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
