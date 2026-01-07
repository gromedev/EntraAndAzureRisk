<#
.SYNOPSIS
    Collects user data with EMBEDDED authentication methods from Microsoft Entra ID
.DESCRIPTION
    Combined collector that:
    - Queries Graph API for users with pagination
    - For each user, queries authentication methods (N+1 pattern)
    - EMBEDS auth method summary directly in user object (denormalized for Power BI)
    - Streams users.jsonl to Blob Storage (memory-efficient)
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
    $usersJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial (larger for embedded auth)
    $writeThreshold = 5000

    # User counters
    $userCount = 0
    $batchNumber = 0
    $enabledCount = 0
    $disabledCount = 0
    $memberCount = 0
    $guestCount = 0

    # Auth methods counters (embedded in users)
    $authMethodsProcessedCount = 0
    $authMethodsErrorCount = 0
    $mfaEnabledCount = 0
    $mfaEnforcedCount = 0
    $mfaDisabledCount = 0
    $usersWithAuthenticatorCount = 0
    $usersWithPhoneCount = 0
    $usersWithFido2Count = 0
    $usersWithWindowsHelloCount = 0

    # Initialize append blob (single file - auth methods embedded in users)
    $usersBlobName = "$timestamp/$timestamp-users.jsonl"
    Write-Verbose "Initializing append blob: $usersBlobName (with embedded auth methods)"

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
            Error   = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query users with field selection
    # Added: lastPasswordChangeDateTime, signInSessionsValidFromDateTime, refreshTokensValidFromDateTime, onPremisesExtensionAttributes
    # Phase 1b: Added mail, mailNickname, proxyAddresses, employeeId, employeeHireDate, employeeType, companyName, mobilePhone, businessPhones, department, jobTitle
    $selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity,displayName,passwordPolicies,usageLocation,externalUserState,externalUserStateChangeDateTime,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesUserPrincipalName,onPremisesSecurityIdentifier,lastPasswordChangeDateTime,signInSessionsValidFromDateTime,refreshTokensValidFromDateTime,onPremisesExtensionAttributes,mail,mailNickname,proxyAddresses,employeeId,employeeHireDate,employeeType,companyName,mobilePhone,businessPhones,department,jobTitle"
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
            $userId = $user.id ?? ""
            $upn = $user.userPrincipalName ?? ""
            $accountEnabled = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }

            # Initialize auth methods fields (will be populated if we can fetch them)
            $perUserMfaState = $null
            $hasAuthenticator = $false
            $hasPhone = $false
            $hasFido2 = $false
            $hasEmail = $false
            $hasPassword = $false
            $hasTap = $false
            $hasWindowsHello = $false
            $hasSoftwareOath = $false
            $methodCount = 0
            $authMethodTypes = @()

            # --- Collect Auth Methods for this user (embedded) ---
            # Skip disabled accounts if configured
            $shouldCollectAuth = -not ($skipDisabledForAuthMethods -and $accountEnabled -eq $false)

            if ($shouldCollectAuth) {
                try {
                    # Get authentication methods
                    $authMethodsUri = "https://graph.microsoft.com/beta/users/$userId/authentication/methods"
                    try {
                        $authMethodsResponse = Invoke-GraphWithRetry -Uri $authMethodsUri -AccessToken $graphToken
                        if ($authMethodsResponse -and $authMethodsResponse.value) {
                            foreach ($method in $authMethodsResponse.value) {
                                $methodType = $method.'@odata.type' -replace '#microsoft.graph.', ''
                                $authMethodTypes += $methodType
                                $methodCount++

                                switch ($methodType) {
                                    'microsoftAuthenticatorAuthenticationMethod' { $hasAuthenticator = $true }
                                    'phoneAuthenticationMethod' { $hasPhone = $true }
                                    'fido2AuthenticationMethod' { $hasFido2 = $true }
                                    'emailAuthenticationMethod' { $hasEmail = $true }
                                    'passwordAuthenticationMethod' { $hasPassword = $true }
                                    'temporaryAccessPassAuthenticationMethod' { $hasTap = $true }
                                    'windowsHelloForBusinessAuthenticationMethod' { $hasWindowsHello = $true }
                                    'softwareOathAuthenticationMethod' { $hasSoftwareOath = $true }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Warning "Failed to get auth methods for user $upn`: $_"
                        $authMethodsErrorCount++
                    }

                    # Get MFA requirements (per-user MFA state)
                    $mfaRequirementsUri = "https://graph.microsoft.com/beta/users/$userId/authentication/requirements"
                    try {
                        $mfaResponse = Invoke-GraphWithRetry -Uri $mfaRequirementsUri -AccessToken $graphToken
                        $perUserMfaState = $mfaResponse.perUserMfaState ?? $null
                    }
                    catch {
                        Write-Warning "Failed to get MFA requirements for user $upn`: $_"
                    }

                    # Track MFA statistics
                    switch ($perUserMfaState) {
                        'enabled' { $mfaEnabledCount++ }
                        'enforced' { $mfaEnforcedCount++ }
                        'disabled' { $mfaDisabledCount++ }
                    }

                    if ($hasAuthenticator) { $usersWithAuthenticatorCount++ }
                    if ($hasPhone) { $usersWithPhoneCount++ }
                    if ($hasFido2) { $usersWithFido2Count++ }
                    if ($hasWindowsHello) { $usersWithWindowsHelloCount++ }

                    $authMethodsProcessedCount++
                }
                catch {
                    Write-Warning "Error processing auth methods for user $upn`: $_"
                    $authMethodsErrorCount++
                }
            }

            # Transform to consistent structure WITH EMBEDDED AUTH METHODS
            $userObj = @{
                # Core identifiers
                objectId                         = $userId
                principalType                    = "user"
                userPrincipalName                = $upn
                displayName                      = $user.displayName ?? $null

                # Account status
                accountEnabled                   = $accountEnabled
                userType                         = $user.userType ?? ""

                # Timestamps
                createdDateTime                  = $user.createdDateTime ?? ""
                lastSignInDateTime               = if ($user.signInActivity.lastSignInDateTime) { $user.signInActivity.lastSignInDateTime } else { $null }

                # Password and location
                passwordPolicies                 = $user.passwordPolicies ?? $null
                usageLocation                    = $user.usageLocation ?? $null

                # External user
                externalUserState                = $user.externalUserState ?? $null
                externalUserStateChangeDateTime  = $user.externalUserStateChangeDateTime ?? $null

                # On-premises sync
                onPremisesSyncEnabled            = if ($null -ne $user.onPremisesSyncEnabled) { $user.onPremisesSyncEnabled } else { $null }
                onPremisesSamAccountName         = $user.onPremisesSamAccountName ?? $null
                onPremisesUserPrincipalName      = $user.onPremisesUserPrincipalName ?? $null
                onPremisesSecurityIdentifier     = $user.onPremisesSecurityIdentifier ?? $null
                onPremisesExtensionAttributes    = $user.onPremisesExtensionAttributes ?? $null

                # Password and session timestamps (security analytics)
                lastPasswordChangeDateTime       = $user.lastPasswordChangeDateTime ?? $null
                signInSessionsValidFromDateTime  = $user.signInSessionsValidFromDateTime ?? $null
                refreshTokensValidFromDateTime   = $user.refreshTokensValidFromDateTime ?? $null

                # Phase 1b: Security-relevant identity fields
                mail                             = $user.mail ?? $null
                mailNickname                     = $user.mailNickname ?? $null
                proxyAddresses                   = $user.proxyAddresses ?? @()
                employeeId                       = $user.employeeId ?? $null
                employeeHireDate                 = $user.employeeHireDate ?? $null
                employeeType                     = $user.employeeType ?? $null
                companyName                      = $user.companyName ?? $null
                mobilePhone                      = $user.mobilePhone ?? $null
                businessPhones                   = $user.businessPhones ?? @()
                department                       = $user.department ?? $null
                jobTitle                         = $user.jobTitle ?? $null

                # EMBEDDED Authentication Methods (denormalized for Power BI)
                perUserMfaState                  = $perUserMfaState
                hasAuthenticator                 = $hasAuthenticator
                hasPhone                         = $hasPhone
                hasFido2                         = $hasFido2
                hasEmail                         = $hasEmail
                hasPassword                      = $hasPassword
                hasTap                           = $hasTap
                hasWindowsHello                  = $hasWindowsHello
                hasSoftwareOath                  = $hasSoftwareOath
                authMethodCount                  = $methodCount
                authMethodTypes                  = $authMethodTypes

                # Collection metadata
                collectionTimestamp              = $timestampFormatted
            }

            [void]$usersJsonL.AppendLine(($userObj | ConvertTo-Json -Compress -Depth 10))
            $userCount++

            # Track user statistics
            if ($accountEnabled -eq $true) { $enabledCount++ }
            elseif ($accountEnabled -eq $false) { $disabledCount++ }

            if ($user.userType -eq 'Member') { $memberCount++ }
            elseif ($user.userType -eq 'Guest') { $guestCount++ }
        }

        # Periodic flush to blob (single file with embedded auth methods)
        if ($usersJsonL.Length -ge ($writeThreshold * 300)) {
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

        Write-Verbose "Batch $batchNumber complete: $userCount users ($authMethodsProcessedCount with auth methods)"
    }

    # Final flush
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

    Write-Verbose "Collection complete: $userCount users with embedded auth methods ($authMethodsProcessedCount processed)"

    # Cleanup
    $usersJsonL.Clear()
    $usersJsonL = $null

    # Create summary (includes embedded auth methods stats)
    $summary = @{
        id                          = $timestamp
        collectionTimestamp         = $timestampFormatted
        collectionType              = 'users'
        totalCount                  = $userCount
        enabledCount                = $enabledCount
        disabledCount               = $disabledCount
        memberCount                 = $memberCount
        guestCount                  = $guestCount
        # Auth methods stats (embedded)
        authMethodsProcessedCount   = $authMethodsProcessedCount
        authMethodsErrorCount       = $authMethodsErrorCount
        mfaEnabledCount             = $mfaEnabledCount
        mfaEnforcedCount            = $mfaEnforcedCount
        mfaDisabledCount            = $mfaDisabledCount
        usersWithAuthenticatorCount = $usersWithAuthenticatorCount
        usersWithPhoneCount         = $usersWithPhoneCount
        usersWithFido2Count         = $usersWithFido2Count
        usersWithWindowsHelloCount  = $usersWithWindowsHelloCount
        blobPath                    = $usersBlobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success                   = $true
        UserCount                 = $userCount
        AuthMethodsProcessedCount = $authMethodsProcessedCount
        AuthMethodsErrorCount     = $authMethodsErrorCount
        Data                      = @()
        Summary                   = $summary
        Timestamp                 = $timestamp
        UsersBlobName             = $usersBlobName
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
