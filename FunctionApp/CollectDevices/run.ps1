<#
.SYNOPSIS
    Collects device data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    V3 Architecture: Unified principals container
    - Queries Graph API /devices with pagination
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
    - Uses principalType="device" discriminator
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
    Write-Verbose "Starting Entra device data collection"

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
    $devicesJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $deviceCount = 0
    $batchNumber = 0
    $writeThreshold = 5000

    # Summary statistics
    $enabledCount = 0
    $disabledCount = 0
    $compliantCount = 0
    $nonCompliantCount = 0
    $managedCount = 0
    $unmanagedCount = 0

    # Initialize append blob (V3: unified principals.jsonl)
    $principalsBlobName = "$timestamp/$timestamp-principals.jsonl"
    Write-Verbose "Initializing append blob: $principalsBlobName"

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $principalsBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query devices with field selection
    # Note: Requires Device.Read.All permission
    # Phase 1b: Added extensionAttributes, onPremisesSyncEnabled, onPremisesLastSyncDateTime, mdmAppId, managementType, systemLabels
    $selectFields = "id,displayName,accountEnabled,deviceId,operatingSystem,operatingSystemVersion,isCompliant,isManaged,trustType,approximateLastSignInDateTime,createdDateTime,deviceVersion,manufacturer,model,profileType,registrationDateTime,extensionAttributes,onPremisesSyncEnabled,onPremisesLastSyncDateTime,mdmAppId,managementType,systemLabels"
    $nextLink = "https://graph.microsoft.com/v1.0/devices?`$select=$selectFields&`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $deviceBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($deviceBatch.Count -eq 0) { break }

        # Process batch
        foreach ($device in $deviceBatch) {
            # Transform to consistent structure with objectId
            $deviceObj = @{
                objectId = $device.id ?? ""
                principalType = "device"
                displayName = $device.displayName ?? ""
                deviceId = $device.deviceId ?? ""
                accountEnabled = if ($null -ne $device.accountEnabled) { $device.accountEnabled } else { $null }
                operatingSystem = $device.operatingSystem ?? ""
                operatingSystemVersion = $device.operatingSystemVersion ?? ""
                isCompliant = if ($null -ne $device.isCompliant) { $device.isCompliant } else { $null }
                isManaged = if ($null -ne $device.isManaged) { $device.isManaged } else { $null }
                trustType = $device.trustType ?? ""
                approximateLastSignInDateTime = $device.approximateLastSignInDateTime ?? $null
                createdDateTime = $device.createdDateTime ?? ""
                deviceVersion = $device.deviceVersion ?? $null
                manufacturer = $device.manufacturer ?? ""
                model = $device.model ?? ""
                profileType = $device.profileType ?? ""
                registrationDateTime = $device.registrationDateTime ?? $null

                # Phase 1b: Security-relevant fields
                extensionAttributes = $device.extensionAttributes ?? $null
                onPremisesSyncEnabled = if ($null -ne $device.onPremisesSyncEnabled) { $device.onPremisesSyncEnabled } else { $null }
                onPremisesLastSyncDateTime = $device.onPremisesLastSyncDateTime ?? $null
                mdmAppId = $device.mdmAppId ?? $null
                managementType = $device.managementType ?? $null
                systemLabels = $device.systemLabels ?? @()

                # V3: Temporal fields for historical tracking
                effectiveFrom = $timestampFormatted
                effectiveTo = $null

                # Collection metadata
                collectionTimestamp = $timestampFormatted
            }

            [void]$devicesJsonL.AppendLine(($deviceObj | ConvertTo-Json -Compress))
            $deviceCount++

            # Track statistics
            if ($deviceObj.accountEnabled -eq $true) { $enabledCount++ }
            elseif ($deviceObj.accountEnabled -eq $false) { $disabledCount++ }

            if ($deviceObj.isCompliant -eq $true) { $compliantCount++ }
            elseif ($deviceObj.isCompliant -eq $false) { $nonCompliantCount++ }

            if ($deviceObj.isManaged -eq $true) { $managedCount++ }
            elseif ($deviceObj.isManaged -eq $false) { $unmanagedCount++ }
        }

        # Periodic flush to blob
        if ($devicesJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $principalsBlobName `
                                -Content $devicesJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($devicesJsonL.Length) characters to principals blob (batch $batchNumber)"
                $devicesJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $deviceCount total devices"
    }

    # Final flush
    if ($devicesJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $principalsBlobName `
                            -Content $devicesJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($devicesJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Device collection complete: $deviceCount devices written to $principalsBlobName"

    # Cleanup
    $devicesJsonL.Clear()
    $devicesJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'devices'
        totalCount = $deviceCount
        enabledCount = $enabledCount
        disabledCount = $disabledCount
        compliantCount = $compliantCount
        nonCompliantCount = $nonCompliantCount
        managedCount = $managedCount
        unmanagedCount = $unmanagedCount
        blobPath = $principalsBlobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success = $true
        DeviceCount = $deviceCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-principals.jsonl"
        Timestamp = $timestamp
        PrincipalsBlobName = $principalsBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectDevices: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
