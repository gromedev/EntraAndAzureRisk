<#
.SYNOPSIS
    Collects user authentication methods from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Uses N+1 pattern: Reads user list from blob, then queries each user's auth methods
    - Queries Graph API beta /users/{id}/authentication/methods for each user
    - Queries Graph API beta /users/{id}/authentication/requirements for MFA state
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
    - Supports parallel API calls for performance

    NOTE: This function requires the users blob to be collected first.
    Pass the users blob path via ActivityInput.UsersBlobName
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
    Write-Verbose "Starting User Authentication Methods data collection"

    # Validate input - need users blob path
    if (-not $ActivityInput.UsersBlobName) {
        $errorMsg = "UsersBlobName is required in ActivityInput. Run CollectEntraUsers first."
        Write-Error $errorMsg
        return @{
            Success = $false
            Error = $errorMsg
        }
    }

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
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Read users from blob
    Write-Verbose "Reading users from blob: $($ActivityInput.UsersBlobName)"
    $usersBlobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$($ActivityInput.UsersBlobName)"

    try {
        $headers = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version' = '2020-04-08'
        }
        $blobResponse = Invoke-RestMethod -Uri $usersBlobUri -Headers $headers -Method Get
        $userLines = $blobResponse -split "`n" | Where-Object { $_.Trim() -ne "" }
        Write-Verbose "Found $($userLines.Count) users in blob"
    }
    catch {
        Write-Error "Failed to read users blob: $_"
        return @{
            Success = $false
            Error = "Failed to read users blob: $($_.Exception.Message)"
        }
    }

    # Initialize counters and buffers
    $authMethodsJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial capacity
    $userCount = 0
    $processedCount = 0
    $errorCount = 0
    $writeThreshold = 2000

    # Summary statistics
    $mfaEnabledCount = 0
    $mfaEnforcedCount = 0
    $mfaDisabledCount = 0
    $usersWithAuthenticatorCount = 0
    $usersWithPhoneCount = 0
    $usersWithFido2Count = 0

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-userauthMethods.jsonl"
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

    # Process users - N+1 pattern
    # Note: Requires UserAuthenticationMethod.Read.All permission (beta API)
    Write-Verbose "Processing users for authentication methods (N+1 pattern)"

    foreach ($userLine in $userLines) {
        $userCount++
        try {
            $user = $userLine | ConvertFrom-Json

            # Skip disabled accounts to reduce API calls (configurable)
            $skipDisabled = if ($env:AUTH_METHODS_SKIP_DISABLED -eq 'false') { $false } else { $true }
            if ($skipDisabled -and $user.accountEnabled -eq $false) {
                Write-Verbose "Skipping disabled user: $($user.userPrincipalName)"
                continue
            }

            $userId = $user.objectId
            $upn = $user.userPrincipalName

            # Get authentication methods
            $authMethodsUri = "https://graph.microsoft.com/beta/users/$userId/authentication/methods"
            $authMethodsResponse = $null
            try {
                $authMethodsResponse = Invoke-GraphWithRetry -Uri $authMethodsUri -AccessToken $graphToken
            }
            catch {
                Write-Warning "Failed to get auth methods for user $upn`: $_"
                $errorCount++
            }

            # Get MFA requirements (per-user MFA state)
            $mfaRequirementsUri = "https://graph.microsoft.com/beta/users/$userId/authentication/requirements"
            $mfaState = 'unknown'
            try {
                $mfaResponse = Invoke-GraphWithRetry -Uri $mfaRequirementsUri -AccessToken $graphToken
                $mfaState = $mfaResponse.perUserMfaState ?? 'unknown'
            }
            catch {
                Write-Warning "Failed to get MFA requirements for user $upn`: $_"
            }

            # Process authentication methods
            $hasAuthenticator = $false
            $hasPhone = $false
            $hasFido2 = $false
            $hasEmail = $false
            $hasPassword = $false
            $hasTap = $false
            $hasWindowsHello = $false

            $methodsList = @()
            if ($authMethodsResponse -and $authMethodsResponse.value) {
                foreach ($method in $authMethodsResponse.value) {
                    $methodType = $method.'@odata.type' -replace '#microsoft.graph.', ''

                    switch ($methodType) {
                        'microsoftAuthenticatorAuthenticationMethod' { $hasAuthenticator = $true }
                        'phoneAuthenticationMethod' { $hasPhone = $true }
                        'fido2AuthenticationMethod' { $hasFido2 = $true }
                        'emailAuthenticationMethod' { $hasEmail = $true }
                        'passwordAuthenticationMethod' { $hasPassword = $true }
                        'temporaryAccessPassAuthenticationMethod' { $hasTap = $true }
                        'windowsHelloForBusinessAuthenticationMethod' { $hasWindowsHello = $true }
                    }

                    $methodsList += @{
                        id = $method.id ?? ""
                        type = $methodType
                        displayName = $method.displayName ?? $null
                    }
                }
            }

            # Track statistics
            switch ($mfaState) {
                'enabled' { $mfaEnabledCount++ }
                'enforced' { $mfaEnforcedCount++ }
                'disabled' { $mfaDisabledCount++ }
            }

            if ($hasAuthenticator) { $usersWithAuthenticatorCount++ }
            if ($hasPhone) { $usersWithPhoneCount++ }
            if ($hasFido2) { $usersWithFido2Count++ }

            # Create auth methods object
            $authMethodsObj = @{
                objectId = $userId
                userPrincipalName = $upn
                displayName = $user.displayName ?? ""
                accountEnabled = $user.accountEnabled
                perUserMfaState = $mfaState
                hasAuthenticator = $hasAuthenticator
                hasPhone = $hasPhone
                hasFido2 = $hasFido2
                hasEmail = $hasEmail
                hasPassword = $hasPassword
                hasTap = $hasTap
                hasWindowsHello = $hasWindowsHello
                methodCount = $methodsList.Count
                methods = $methodsList
                collectionTimestamp = $timestampFormatted
            }

            [void]$authMethodsJsonL.AppendLine(($authMethodsObj | ConvertTo-Json -Compress -Depth 10))
            $processedCount++

            # Progress logging every 100 users
            if ($processedCount % 100 -eq 0) {
                Write-Verbose "Processed $processedCount users..."
            }

            # Periodic flush to blob
            if ($authMethodsJsonL.Length -ge ($writeThreshold * 500)) {
                try {
                    Add-BlobContent -StorageAccountName $storageAccountName `
                                    -ContainerName $containerName `
                                    -BlobName $blobName `
                                    -Content $authMethodsJsonL.ToString() `
                                    -AccessToken $storageToken `
                                    -MaxRetries 3 `
                                    -BaseRetryDelaySeconds 2

                    Write-Verbose "Flushed $($authMethodsJsonL.Length) characters to blob"
                    $authMethodsJsonL.Clear()
                }
                catch {
                    Write-Error "CRITICAL: Blob write failed after retries $_"
                    throw "Cannot continue - data loss would occur"
                }
            }
        }
        catch {
            Write-Warning "Error processing user at line $userCount`: $_"
            $errorCount++
        }
    }

    # Final flush
    if ($authMethodsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $authMethodsJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($authMethodsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "User auth methods collection complete: $processedCount users written to $blobName"

    # Cleanup
    $authMethodsJsonL.Clear()
    $authMethodsJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'userAuthMethods'
        totalUsersInBlob = $userCount
        processedCount = $processedCount
        errorCount = $errorCount
        mfaEnabledCount = $mfaEnabledCount
        mfaEnforcedCount = $mfaEnforcedCount
        mfaDisabledCount = $mfaDisabledCount
        usersWithAuthenticatorCount = $usersWithAuthenticatorCount
        usersWithPhoneCount = $usersWithPhoneCount
        usersWithFido2Count = $usersWithFido2Count
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
        ProcessedCount = $processedCount
        ErrorCount = $errorCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-userauthMethods.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
    }
}
catch {
    Write-Error "Unexpected error in CollectUserAuthMethods: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
