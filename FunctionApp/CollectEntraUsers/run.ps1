<#
.SYNOPSIS
    Collects user data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API with pagination
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
    Write-Verbose "Starting Entra user data collection"
    
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
    $usersJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $userCount = 0
    $batchNumber = 0
    $writeThreshold = 5000
    
    # Summary statistics
    $enabledCount = 0
    $disabledCount = 0
    $memberCount = 0
    $guestCount = 0
    
    # Initialize append blob
    $usersBlobName = "$timestamp/$timestamp-users.jsonl"
    Write-Verbose "Initializing append blob: $usersBlobName"
    
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    
    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $usersBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }
    
    # Query users with field selection
    $selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity"
    $nextLink = "https://graph.microsoft.com/v1.0/users?`$select=$selectFields&`$top=$batchSize"
    
    Write-Verbose "Starting batch processing with streaming writes"
    
    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."
        
        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $userBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }
        
        if ($userBatch.Count -eq 0) { break }
        
        # Sequential process batch (82% faster than parallel for small per-item work)
        foreach ($user in $userBatch) {
            # Transform to consistent camelCase structure with objectId
            $userObj = @{
                objectId = $user.id ?? ""
                userPrincipalName = $user.userPrincipalName ?? ""
                accountEnabled = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }
                userType = $user.userType ?? ""
                createdDateTime = $user.createdDateTime ?? ""
                lastSignInDateTime = if ($user.signInActivity.lastSignInDateTime) { 
                    $user.signInActivity.lastSignInDateTime 
                } else { 
                    $null 
                }
                collectionTimestamp = $timestampFormatted
            }
            
            [void]$usersJsonL.AppendLine(($userObj | ConvertTo-Json -Compress))
            $userCount++
            
            # Track summary statistics
            if ($userObj.accountEnabled -eq $true) { $enabledCount++ }
            elseif ($userObj.accountEnabled -eq $false) { $disabledCount++ }
            
            if ($userObj.userType -eq 'Member') { $memberCount++ }
            elseif ($userObj.userType -eq 'Guest') { $guestCount++ }
        }
        
        # Periodic flush to blob (every ~5000 users)
        if ($usersJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $usersBlobName `
                                -Content $usersJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2
                
                Write-Verbose "Flushed $($usersJsonL.Length) characters to blob (batch $batchNumber)"
                $usersJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }
        
        Write-Verbose "Batch $batchNumber complete: $userCount total users"
    }
    
    # Final flush
    if ($usersJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName 'raw-data' `
                            -BlobName $usersBlobName `
                            -Content $usersJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($usersJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }
    
    Write-Verbose "User collection complete: $userCount users written to $usersBlobName"
    
    # Cleanup
    $usersJsonL.Clear()
    $usersJsonL = $null
    
    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'users'
        totalCount = $userCount
        enabledCount = $enabledCount
        disabledCount = $disabledCount
        memberCount = $memberCount
        guestCount = $guestCount
        blobPath = $usersBlobName
    }
    
    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
    
    Write-Verbose "Collection activity completed successfully!"
    
    return @{
        Success = $true
        UserCount = $userCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-users.jsonl"
        Timestamp = $timestamp
        BlobName = $usersBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectEntraUsers: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
