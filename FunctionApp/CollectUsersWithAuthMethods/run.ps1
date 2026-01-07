<#
.SYNOPSIS
    Collects user data AND authentication methods from Microsoft Entra ID
.DESCRIPTION
    Combined collector that:
    - Queries Graph API for users with pagination
    - For each user, queries authentication methods (N+1 pattern)
    - Streams both users.jsonl and userAuthMethods.jsonl to Blob Storage
    - Eliminates intermediate blob read (users already in memory)
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
        Error   = $errorMsg
    }
}
#endregion

#region Validate Environment Variables
$requiredEnvVars = @{
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
    'COSMOS_DB_ENDPOINT'   = 'Cosmos DB endpoint for indexing'
    'COSMOS_DB_DATABASE'   = 'Cosmos DB database name'
    'TENANT_ID'            = 'Entra ID tenant ID'
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
        Error   = $errorMsg
    }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting combined Users + AuthMethods data collection"

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
            Error   = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $skipDisabledForAuthMethods = if ($env:AUTH_METHODS_SKIP_DISABLED -eq 'false') { $false } else { $true }

    Write-Verbose "Configuration: Batch=$batchSize, SkipDisabledForAuth=$skipDisabledForAuthMethods"

    # Initialize buffers
    $usersJsonL = New-Object System.Text.StringBuilder(1048576)       # 1MB initial
    $authMethodsJsonL = New-Object System.Text.StringBuilder(2097152) # 2MB initial
    $writeThreshold = 5000

    # User counters
    $userCount = 0
    $batchNumber = 0
    $enabledCount = 0
    $disabledCount = 0
    $memberCount = 0
    $guestCount = 0

    # Auth methods counters
    $authMethodsProcessedCount = 0
    $authMethodsErrorCount = 0
    $mfaEnabledCount = 0
    $mfaEnforcedCount = 0
    $mfaDisabledCount = 0
    $usersWithAuthenticatorCount = 0
    $usersWithPhoneCount = 0
    $usersWithFido2Count = 0

    # Initialize append blobs
    $usersBlobName = "$timestamp/$timestamp-users.jsonl"
    $authMethodsBlobName = "$timestamp/$timestamp-userauthMethods.jsonl"
    Write-Verbose "Initializing append blobs: $usersBlobName, $authMethodsBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
            -ContainerName $containerName `
            -BlobName $usersBlobName `
            -AccessToken $storageToken

        Initialize-AppendBlob -StorageAccountName $storageAccountName `
            -ContainerName $containerName `
            -BlobName $authMethodsBlobName `
            -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blobs: $_"
        return @{
            Success = $false
            Error   = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query users with field selection
    $selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity,displayName,passwordPolicies,usageLocation,externalUserState,externalUserStateChangeDateTime,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesUserPrincipalName,onPremisesSecurityIdentifier"
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

        # Process each user
        foreach ($user in $userBatch) {
            # Transform to consistent structure
            $userObj = @{
                objectId                         = $user.id ?? ""
                principalType                    = "user"
                userPrincipalName                = $user.userPrincipalName ?? ""
                accountEnabled                   = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }
                userType                         = $user.userType ?? ""
                createdDateTime                  = $user.createdDateTime ?? ""
                lastSignInDateTime               = if ($user.signInActivity.lastSignInDateTime) { $user.signInActivity.lastSignInDateTime } else { $null }
                displayName                      = $user.displayName ?? $null
                passwordPolicies                 = $user.passwordPolicies ?? $null
                usageLocation                    = $user.usageLocation ?? $null
                externalUserState                = $user.externalUserState ?? $null
                externalUserStateChangeDateTime  = $user.externalUserStateChangeDateTime ?? $null
                onPremisesSyncEnabled            = if ($null -ne $user.onPremisesSyncEnabled) { $user.onPremisesSyncEnabled } else { $null }
                onPremisesSamAccountName         = $user.onPremisesSamAccountName ?? $null
                onPremisesUserPrincipalName      = $user.onPremisesUserPrincipalName ?? $null
                onPremisesSecurityIdentifier     = $user.onPremisesSecurityIdentifier ?? $null
                collectionTimestamp              = $timestampFormatted
            }

            [void]$usersJsonL.AppendLine(($userObj | ConvertTo-Json -Compress))
            $userCount++

            # Track user statistics
            if ($userObj.accountEnabled -eq $true) { $enabledCount++ }
            elseif ($userObj.accountEnabled -eq $false) { $disabledCount++ }

            if ($userObj.userType -eq 'Member') { $memberCount++ }
            elseif ($userObj.userType -eq 'Guest') { $guestCount++ }

            # --- Collect Auth Methods for this user ---
            # Skip disabled accounts if configured
            if ($skipDisabledForAuthMethods -and $userObj.accountEnabled -eq $false) {
                continue
            }

            try {
                $userId = $userObj.objectId
                $upn = $userObj.userPrincipalName

                # Get authentication methods
                $authMethodsUri = "https://graph.microsoft.com/beta/users/$userId/authentication/methods"
                $authMethodsResponse = $null
                try {
                    $authMethodsResponse = Invoke-GraphWithRetry -Uri $authMethodsUri -AccessToken $graphToken
                }
                catch {
                    Write-Warning "Failed to get auth methods for user $upn`: $_"
                    $authMethodsErrorCount++
                }

                # Get MFA requirements
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
                            id          = $method.id ?? ""
                            type        = $methodType
                            displayName = $method.displayName ?? $null
                        }
                    }
                }

                # Track MFA statistics
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
                    objectId            = $userId
                    userPrincipalName   = $upn
                    displayName         = $userObj.displayName ?? ""
                    accountEnabled      = $userObj.accountEnabled
                    perUserMfaState     = $mfaState
                    hasAuthenticator    = $hasAuthenticator
                    hasPhone            = $hasPhone
                    hasFido2            = $hasFido2
                    hasEmail            = $hasEmail
                    hasPassword         = $hasPassword
                    hasTap              = $hasTap
                    hasWindowsHello     = $hasWindowsHello
                    methodCount         = $methodsList.Count
                    methods             = $methodsList
                    collectionTimestamp = $timestampFormatted
                }

                [void]$authMethodsJsonL.AppendLine(($authMethodsObj | ConvertTo-Json -Compress -Depth 10))
                $authMethodsProcessedCount++
            }
            catch {
                Write-Warning "Error processing auth methods for user: $_"
                $authMethodsErrorCount++
            }
        }

        # Periodic flush to blobs
        if ($usersJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                    -ContainerName $containerName `
                    -BlobName $usersBlobName `
                    -Content $usersJsonL.ToString() `
                    -AccessToken $storageToken `
                    -MaxRetries 3 `
                    -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($usersJsonL.Length) chars to users blob (batch $batchNumber)"
                $usersJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Users blob write failed after retries at batch $batchNumber $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        if ($authMethodsJsonL.Length -ge ($writeThreshold * 500)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                    -ContainerName $containerName `
                    -BlobName $authMethodsBlobName `
                    -Content $authMethodsJsonL.ToString() `
                    -AccessToken $storageToken `
                    -MaxRetries 3 `
                    -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($authMethodsJsonL.Length) chars to authMethods blob"
                $authMethodsJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: AuthMethods blob write failed after retries $_"
                throw "Cannot continue - data loss would occur"
            }
        }

        Write-Verbose "Batch $batchNumber complete: $userCount users, $authMethodsProcessedCount auth methods"
    }

    # Final flush - users
    if ($usersJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                -ContainerName $containerName `
                -BlobName $usersBlobName `
                -Content $usersJsonL.ToString() `
                -AccessToken $storageToken `
                -MaxRetries 3 `
                -BaseRetryDelaySeconds 2
            Write-Verbose "Final users flush: $($usersJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final users flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    # Final flush - auth methods
    if ($authMethodsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                -ContainerName $containerName `
                -BlobName $authMethodsBlobName `
                -Content $authMethodsJsonL.ToString() `
                -AccessToken $storageToken `
                -MaxRetries 3 `
                -BaseRetryDelaySeconds 2
            Write-Verbose "Final authMethods flush: $($authMethodsJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final authMethods flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Combined collection complete: $userCount users, $authMethodsProcessedCount auth methods"

    # Cleanup
    $usersJsonL.Clear()
    $usersJsonL = $null
    $authMethodsJsonL.Clear()
    $authMethodsJsonL = $null

    # Create summaries
    $usersSummary = @{
        id                  = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType      = 'users'
        totalCount          = $userCount
        enabledCount        = $enabledCount
        disabledCount       = $disabledCount
        memberCount         = $memberCount
        guestCount          = $guestCount
        blobPath            = $usersBlobName
    }

    $authMethodsSummary = @{
        id                         = $timestamp
        collectionTimestamp        = $timestampFormatted
        collectionType             = 'userAuthMethods'
        totalUsersInBlob           = $userCount
        processedCount             = $authMethodsProcessedCount
        errorCount                 = $authMethodsErrorCount
        mfaEnabledCount            = $mfaEnabledCount
        mfaEnforcedCount           = $mfaEnforcedCount
        mfaDisabledCount           = $mfaDisabledCount
        usersWithAuthenticatorCount = $usersWithAuthenticatorCount
        usersWithPhoneCount        = $usersWithPhoneCount
        usersWithFido2Count        = $usersWithFido2Count
        blobPath                   = $authMethodsBlobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Combined collection activity completed successfully!"

    return @{
        Success                 = $true
        UserCount               = $userCount
        AuthMethodsProcessedCount = $authMethodsProcessedCount
        AuthMethodsErrorCount   = $authMethodsErrorCount
        Data                    = @()
        UsersSummary            = $usersSummary
        AuthMethodsSummary      = $authMethodsSummary
        Timestamp               = $timestamp
        UsersBlobName           = $usersBlobName
        AuthMethodsBlobName     = $authMethodsBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectUsersWithAuthMethods: $_"
    return @{
        Success = $false
        Error   = $_.Exception.Message
    }
}
#endregion
