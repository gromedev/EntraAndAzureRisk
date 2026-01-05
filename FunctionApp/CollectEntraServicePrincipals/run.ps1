<#
.SYNOPSIS
    Collects service principal data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API (v1.0 endpoint for service principals)
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
    Write-Verbose "Starting Entra service principal data collection"

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
    $servicePrincipalsJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $servicePrincipalCount = 0
    $batchNumber = 0
    $writeThreshold = 5000

    # Summary statistics
    $accountEnabledCount = 0
    $accountDisabledCount = 0
    $applicationTypeCount = 0
    $managedIdentityTypeCount = 0
    $legacyTypeCount = 0
    $socialIdpTypeCount = 0

    # Initialize append blob
    $servicePrincipalsBlobName = "$timestamp/$timestamp-serviceprincipals.jsonl"
    Write-Verbose "Initializing append blob: $servicePrincipalsBlobName"

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $servicePrincipalsBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query service principals with field selection
    $selectFields = "id,appDisplayName,accountEnabled,addIns,displayName,appId,appRoleAssignmentRequired,deletedDateTime,description,oauth2PermissionScopes,resourceSpecificApplicationPermissions,servicePrincipalNames,servicePrincipalType,tags,notes"
    $nextLink = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=$selectFields&`$top=$batchSize"

    Write-Verbose "Starting batch processing with streaming writes"

    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."

        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $servicePrincipalBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }

        if ($servicePrincipalBatch.Count -eq 0) { break }

        # Sequential process batch
        foreach ($sp in $servicePrincipalBatch) {
            # Transform to consistent camelCase structure with objectId
            $servicePrincipalObj = @{
                # Core identifiers
                objectId = $sp.id ?? ""
                appId = $sp.appId ?? ""
                displayName = $sp.displayName ?? ""
                servicePrincipalType = $sp.servicePrincipalType ?? ""

                # Boolean flags
                accountEnabled = if ($null -ne $sp.accountEnabled) { $sp.accountEnabled } else { $null }
                appRoleAssignmentRequired = if ($null -ne $sp.appRoleAssignmentRequired) { $sp.appRoleAssignmentRequired } else { $null }

                # DateTime fields
                deletedDateTime = $sp.deletedDateTime ?? $null

                # Text fields
                appDisplayName = $sp.appDisplayName ?? $null
                description = $sp.description ?? $null
                notes = $sp.notes ?? $null

                # Array fields
                addIns = $sp.addIns ?? @()
                oauth2PermissionScopes = $sp.oauth2PermissionScopes ?? @()
                resourceSpecificApplicationPermissions = $sp.resourceSpecificApplicationPermissions ?? @()
                servicePrincipalNames = $sp.servicePrincipalNames ?? @()
                tags = $sp.tags ?? @()

                # Locally-generated property (collection metadata)
                collectionTimestamp = $timestampFormatted
            }

            [void]$servicePrincipalsJsonL.AppendLine(($servicePrincipalObj | ConvertTo-Json -Depth 10 -Compress))
            $servicePrincipalCount++

            # Track summary statistics
            if ($servicePrincipalObj.accountEnabled -eq $true) { $accountEnabledCount++ }
            elseif ($servicePrincipalObj.accountEnabled -eq $false) { $accountDisabledCount++ }

            # Track service principal types
            switch ($servicePrincipalObj.servicePrincipalType) {
                'Application' { $applicationTypeCount++ }
                'ManagedIdentity' { $managedIdentityTypeCount++ }
                'Legacy' { $legacyTypeCount++ }
                'SocialIdp' { $socialIdpTypeCount++ }
            }
        }

        # Periodic flush to blob (every ~5000 service principals)
        if ($servicePrincipalsJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $servicePrincipalsBlobName `
                                -Content $servicePrincipalsJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($servicePrincipalsJsonL.Length) characters to blob (batch $batchNumber)"
                $servicePrincipalsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $servicePrincipalCount total service principals"
    }

    # Final flush
    if ($servicePrincipalsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $servicePrincipalsBlobName `
                            -Content $servicePrincipalsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($servicePrincipalsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Service principal collection complete: $servicePrincipalCount service principals written to $servicePrincipalsBlobName"

    # Cleanup
    $servicePrincipalsJsonL.Clear()
    $servicePrincipalsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'servicePrincipals'
        totalCount = $servicePrincipalCount
        accountEnabledCount = $accountEnabledCount
        accountDisabledCount = $accountDisabledCount
        applicationTypeCount = $applicationTypeCount
        managedIdentityTypeCount = $managedIdentityTypeCount
        legacyTypeCount = $legacyTypeCount
        socialIdpTypeCount = $socialIdpTypeCount
        blobPath = $servicePrincipalsBlobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success = $true
        ServicePrincipalCount = $servicePrincipalCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-serviceprincipals.jsonl"
        Timestamp = $timestamp
        BlobName = $servicePrincipalsBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectEntraServicePrincipals: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
