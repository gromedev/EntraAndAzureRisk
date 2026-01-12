<#
.SYNOPSIS
    Collects App Registration data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    V3 Architecture: Unified resources container
    - Queries Graph API /applications with pagination
    - Includes keyCredentials (certificates) and passwordCredentials (secrets)
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
    - Uses resourceType="application" discriminator (applications are resources, not principals)
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

    # V3: Use shared timestamp from orchestrator (critical for unified blob files)
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'
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
    $writeThreshold = 2000000  # 2MB before flush

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

    # Initialize append blob (V3: unified resources.jsonl)
    $resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
    Write-Verbose "Initializing append blob: $resourcesBlobName"

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $resourcesBlobName `
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
    # Removed rarely-populated fields: optionalClaims, groupMembershipClaims
    $selectFields = "id,appId,displayName,createdDateTime,signInAudience,publisherDomain,keyCredentials,passwordCredentials,requiredResourceAccess,verifiedPublisher,identifierUris,web,publicClient,spa"
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

        # --- BATCH: Get federated identity credentials for all apps in this batch ---
        $batchRequests = @($appBatch | ForEach-Object {
            @{
                id = $_.id
                method = "GET"
                url = "/applications/$($_.id)/federatedIdentityCredentials"
            }
        })

        # Execute batch request for FICs
        $ficBatchResponses = Invoke-GraphBatch -Requests $batchRequests -AccessToken $graphToken

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

            # Get federated identity credentials from batch results
            $federatedCredentials = @()
            $hasFederatedCredentials = $false
            $fedCredsResponse = $ficBatchResponses[$app.id]
            if ($null -ne $fedCredsResponse -and $fedCredsResponse.value -and $fedCredsResponse.value.Count -gt 0) {
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

            # Transform to V3 structure with resourceType discriminator
            $appObj = @{
                objectId = $app.id ?? ""
                resourceType = "application"
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

                # Phase 1b: Security-relevant fields
                identifierUris = $app.identifierUris ?? @()
                web = $app.web ?? $null
                publicClient = $app.publicClient ?? $null
                spa = $app.spa ?? $null
                optionalClaims = $app.optionalClaims ?? $null
                groupMembershipClaims = $app.groupMembershipClaims ?? $null

                # V3: Temporal fields for historical tracking
                effectiveFrom = $timestampFormatted
                effectiveTo = $null

                # Collection metadata
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
                                -BlobName $resourcesBlobName `
                                -Content $appsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($appsJsonL.Length) characters to resources blob (batch $batchNumber)"
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
    Write-Information "[DEBUG] AppCount=$appCount, BufferLength=$($appsJsonL.Length), BlobName=$resourcesBlobName" -InformationAction Continue

    if ($appsJsonL.Length -gt 0) {
        Write-Information "[DEBUG] Starting final flush of $($appsJsonL.Length) characters to $resourcesBlobName" -InformationAction Continue
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $resourcesBlobName `
                            -Content $appsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Information "[DEBUG] Final flush completed successfully" -InformationAction Continue
            Write-Verbose "Final flush: $($appsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    } else {
        Write-Information "[DEBUG] Buffer is empty, skipping final flush" -InformationAction Continue
    }

    Write-Information "[DEBUG] App Registration collection complete: $appCount apps to $resourcesBlobName" -InformationAction Continue
    Write-Verbose "App Registration collection complete: $appCount apps written to $resourcesBlobName"

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
        blobPath = $resourcesBlobName
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
        FileName = "$timestamp-resources.jsonl"
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
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
