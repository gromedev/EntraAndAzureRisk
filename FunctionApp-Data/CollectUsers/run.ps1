<#
.SYNOPSIS
    Collects user data with EMBEDDED authentication methods, risk data, and license info from Microsoft Entra ID
.DESCRIPTION
    Unified User Collector:
    - Queries Graph API for users with pagination
    - For each user, queries authentication methods (N+1 pattern)
    - EMBEDS auth method summary directly in user object (denormalized for Power BI)
    - EMBEDS Identity Protection risk data (requires P2 license)
    - EMBEDS License/SKU data for easy filtering (e.g., "show users with P2")
    - Streams principals.jsonl to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)

    Risk Data Fields (from /identityProtection/riskyUsers):
    - riskLevel: none, low, medium, high, hidden
    - riskState: atRisk, confirmedCompromised, remediated, dismissed, etc.
    - riskDetail: reason for risk
    - isAtRisk: boolean flag for easy filtering

    License Data Fields (from user.assignedLicenses + subscribedSkus):
    - assignedLicenseSkus: array of SKU part numbers (e.g., ["ENTERPRISEPREMIUM", "EMSPREMIUM"])
    - hasP2License: boolean - user has Azure AD Premium P2 or equivalent
    - hasE5License: boolean - user has Microsoft 365 E5 or equivalent
    - licenseCount: number of licenses assigned

    Permission: IdentityRiskyUser.Read.All (requires Azure AD Premium P2)
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

    # V3: Use shared timestamp from orchestrator (critical for unified blob files)
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        # Fallback for manual testing
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
            Error   = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $skipDisabledForAuthMethods = if ($env:AUTH_METHODS_SKIP_DISABLED -eq 'false') { $false } else { $true }

    Write-Verbose "Configuration: Batch=$batchSize, SkipDisabledForAuth=$skipDisabledForAuthMethods"

    # Performance timer to measure batch optimization impact
    $perfTimer = New-PerformanceTimer

    #region Build Risky Users Lookup (Identity Protection - requires P2 license)
    Write-Verbose "Building risky users lookup from Identity Protection..."
    $riskyUsersLookup = @{}
    $riskyUsersCount = 0
    $riskDataAvailable = $false
    $riskDataError = $null
    try {
        $riskyUri = "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$select=id,riskLevel,riskState,riskDetail,riskLastUpdatedDateTime"
        while ($riskyUri) {
            $riskyResponse = Invoke-GraphWithRetry -Uri $riskyUri -AccessToken $graphToken
            foreach ($ru in $riskyResponse.value) {
                $riskyUsersLookup[$ru.id] = $ru
                $riskyUsersCount++
            }
            $riskyUri = $riskyResponse.'@odata.nextLink'
        }
        $riskDataAvailable = $true
        Write-Verbose "Loaded $riskyUsersCount risky users into lookup (P2 license available)"
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match '403|Forbidden|Authorization_RequestDenied') {
            $riskDataError = "P2_LICENSE_REQUIRED"
            Write-Warning "Identity Protection API returned 403 - Azure AD Premium P2 license is required for risk data. Users will be collected without risk fields (riskLevel, riskState, isAtRisk will default to none/null/false)."
        } elseif ($errorMessage -match 'IdentityRiskyUser') {
            $riskDataError = "PERMISSION_MISSING"
            Write-Warning "IdentityRiskyUser.Read.All permission not granted to managed identity - risk data will not be embedded. Grant this permission and re-deploy to enable risk data."
        } else {
            $riskDataError = "API_ERROR: $errorMessage"
            Write-Warning "Failed to retrieve risky users: $errorMessage - risk data will not be embedded"
        }
        # Continue without risk data - non-critical for user collection
    }
    #endregion

    #region Build License SKU Lookup
    Write-Verbose "Building license SKU lookup..."
    $skuLookup = @{}
    try {
        $skusResponse = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -AccessToken $graphToken
        foreach ($sku in $skusResponse.value) {
            $skuLookup[$sku.skuId] = $sku.skuPartNumber
        }
        Write-Verbose "Loaded $($skuLookup.Count) license SKUs into lookup"
    }
    catch {
        Write-Warning "Failed to load SKU lookup: $_ - license names will use raw GUIDs"
    }
    #endregion

    # Initialize buffers
    $usersJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial (larger for embedded auth)
    $writeThreshold = 2000000  # 2MB before flush

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

    # Risk data counters (embedded in users)
    $usersAtRiskCount = 0
    $highRiskCount = 0
    $mediumRiskCount = 0
    $lowRiskCount = 0

    # License counters (embedded in users)
    $usersWithP2Count = 0
    $usersWithE5Count = 0
    $unlicensedCount = 0

    # Initialize append blob (V3: unified principals.jsonl)
    $principalsBlobName = "$timestamp/$timestamp-principals.jsonl"
    Write-Verbose "Initializing append blob: $principalsBlobName (with embedded auth methods)"

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
            Error   = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query users with field selection
    # Removed rarely-populated fields: passwordPolicies, employeeId, employeeHireDate, employeeType, companyName, mobilePhone
    $selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity,displayName,usageLocation,externalUserState,externalUserStateChangeDateTime,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesUserPrincipalName,onPremisesSecurityIdentifier,lastPasswordChangeDateTime,signInSessionsValidFromDateTime,refreshTokensValidFromDateTime,onPremisesExtensionAttributes,mail,mailNickname,proxyAddresses,businessPhones,department,jobTitle,assignedLicenses"

    #region Delta Query for Conditional Auth Methods Collection (Phase 2b)
    # Check if delta sync is enabled (via environment variable or activity input)
    $useDeltaSync = $false
    if ($ActivityInput -and $ActivityInput.UseDelta -eq $true) {
        $useDeltaSync = $true
    }
    elseif ($env:DELTA_SYNC_ENABLED -eq 'true') {
        $useDeltaSync = $true
    }

    # Track delta query results - determines which users need auth methods collected
    $changedUserIds = [System.Collections.Generic.HashSet[string]]::new()
    $isFullSync = $true
    $deltaAuthSkippedCount = 0

    if ($useDeltaSync -and $storageAccountName) {
        Write-Information "[USER-DELTA] Delta sync enabled - querying for changed users" -InformationAction Continue
        try {
            $deltaResult = Invoke-GraphDelta -ResourceType "users" `
                -Select "id" `
                -GraphToken $graphToken `
                -StorageAccountName $storageAccountName `
                -StorageToken $storageToken

            $isFullSync = $deltaResult.IsFullSync

            # Build HashSet of changed user IDs for O(1) lookup
            foreach ($entity in $deltaResult.Entities) {
                [void]$changedUserIds.Add($entity.id)
            }
            # Also include removed IDs (in case we need to track deletions)
            foreach ($removedId in $deltaResult.RemovedIds) {
                [void]$changedUserIds.Add($removedId)
            }

            Write-Information "[USER-DELTA] Delta result: $($changedUserIds.Count) changed users, IsFullSync=$isFullSync" -InformationAction Continue
        }
        catch {
            Write-Warning "[USER-DELTA] Delta query failed, falling back to full sync: $_"
            $isFullSync = $true
            $changedUserIds.Clear()
        }
    }
    #endregion

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

        # --- BATCH: Collect Auth Methods for users in this batch (using Graph $batch API) ---
        # Build list of users that need auth methods collected
        # Phase 2b: For incremental sync, only collect for changed users
        $usersForAuth = @($userBatch | Where-Object {
            $acctEnabled = if ($null -ne $_.accountEnabled) { $_.accountEnabled } else { $null }
            $skipDisabled = ($skipDisabledForAuthMethods -and $acctEnabled -eq $false)

            # Delta check: Skip auth methods for unchanged users during incremental sync
            $skipUnchanged = $false
            if (-not $isFullSync) {
                # Incremental sync: Only collect auth for users in the changed set
                # If no users changed (changedUserIds.Count = 0), skip ALL auth collection
                if ($changedUserIds.Count -eq 0 -or -not $changedUserIds.Contains($_.id)) {
                    $skipUnchanged = $true
                    $script:deltaAuthSkippedCount++
                }
            }

            -not $skipDisabled -and -not $skipUnchanged
        })

        # Initialize results hashtables
        $authMethodsResults = @{}
        $mfaRequirementsResults = @{}

        if ($usersForAuth.Count -gt 0) {
            # Time the batch auth methods calls
            $perfTimer.Start("AuthMethodsBatch_$batchNumber")

            # Build batch requests for auth methods (beta API)
            $authBatchRequests = @($usersForAuth | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/users/$($_.id)/authentication/methods"
                }
            })

            # Build batch requests for MFA requirements (beta API)
            $mfaBatchRequests = @($usersForAuth | ForEach-Object {
                @{
                    id = $_.id
                    method = "GET"
                    url = "/users/$($_.id)/authentication/requirements"
                }
            })

            # Execute batch requests (beta API for auth methods)
            $authMethodsResults = Invoke-GraphBatch -Requests $authBatchRequests -AccessToken $graphToken -ApiVersion "beta"
            $mfaRequirementsResults = Invoke-GraphBatch -Requests $mfaBatchRequests -AccessToken $graphToken -ApiVersion "beta"

            $perfTimer.Stop("AuthMethodsBatch_$batchNumber")
        }

        # Process each user
        foreach ($user in $userBatch) {
            $userId = $user.id ?? ""
            $upn = $user.userPrincipalName ?? ""
            $accountEnabled = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }

            # Initialize auth methods fields (will be populated from batch results)
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
            $authMethodTypes = [System.Collections.Generic.List[string]]::new()

            # --- Process Auth Methods from batch results ---
            # Check if user was included in the batch request (accounts for both disabled and delta filtering)
            $authMethodsResponse = $authMethodsResults[$userId]
            $wasInBatchRequest = $authMethodsResults.ContainsKey($userId)

            if ($wasInBatchRequest -and $null -ne $authMethodsResponse -and $authMethodsResponse.value) {
                foreach ($method in $authMethodsResponse.value) {
                    $methodType = $method.'@odata.type' -replace '#microsoft.graph.', ''
                    $authMethodTypes.Add($methodType)
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
            elseif ($wasInBatchRequest -and $null -eq $authMethodsResponse) {
                $authMethodsErrorCount++
            }

            # Determine if this user should have had auth methods collected
            $shouldCollectAuth = -not ($skipDisabledForAuthMethods -and $accountEnabled -eq $false)
            if ($shouldCollectAuth -and -not $wasInBatchRequest) {
                # User was skipped due to delta filtering (not disabled)
                # Don't count as error - this is expected behavior for incremental sync
            }
            elseif ($wasInBatchRequest) {

                # Process MFA requirements from batch result
                $mfaResponse = $mfaRequirementsResults[$userId]
                if ($null -ne $mfaResponse) {
                    $perUserMfaState = $mfaResponse.perUserMfaState ?? $null
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

            # --- Look up risk data for this user (embedded) ---
            $riskData = $riskyUsersLookup[$userId]
            $riskLevel = if ($riskData) { $riskData.riskLevel } else { "none" }
            $riskState = if ($riskData) { $riskData.riskState } else { $null }
            $riskDetail = if ($riskData) { $riskData.riskDetail } else { $null }
            $riskLastUpdatedDateTime = if ($riskData) { $riskData.riskLastUpdatedDateTime } else { $null }
            $isAtRisk = ($null -ne $riskData)

            # Track risk statistics
            if ($isAtRisk) {
                $usersAtRiskCount++
                switch ($riskLevel) {
                    'high' { $highRiskCount++ }
                    'medium' { $mediumRiskCount++ }
                    'low' { $lowRiskCount++ }
                }
            }

            # --- Map assigned licenses to SKU names (embedded) ---
            $assignedLicenseSkus = @()
            foreach ($license in ($user.assignedLicenses ?? @())) {
                $skuId = $license.skuId
                $skuName = if ($skuLookup[$skuId]) { $skuLookup[$skuId] } else { $skuId }
                $assignedLicenseSkus += $skuName
            }

            # Determine license flags (common high-value license patterns)
            $hasP2License = ($assignedLicenseSkus | Where-Object { $_ -match 'EMSPREMIUM|AAD_PREMIUM_P2|M365_E5|SPE_E5' }).Count -gt 0
            $hasE5License = ($assignedLicenseSkus | Where-Object { $_ -match 'SPE_E5|ENTERPRISEPREMIUM|M365_E5' }).Count -gt 0
            $licenseCount = $assignedLicenseSkus.Count

            # Track license statistics
            if ($hasP2License) { $usersWithP2Count++ }
            if ($hasE5License) { $usersWithE5Count++ }
            if ($licenseCount -eq 0) { $unlicensedCount++ }

            # Transform to consistent structure with embedded auth methods, risk data, and licenses
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

                # EMBEDDED Risk Data (Identity Protection - requires P2 license)
                riskLevel                        = $riskLevel
                riskState                        = $riskState
                riskDetail                       = $riskDetail
                riskLastUpdatedDateTime          = $riskLastUpdatedDateTime
                isAtRisk                         = $isAtRisk

                # EMBEDDED License Data (for easy filtering without edge joins)
                assignedLicenseSkus              = $assignedLicenseSkus
                hasP2License                     = $hasP2License
                hasE5License                     = $hasE5License
                licenseCount                     = $licenseCount

                # V3: Temporal fields for historical tracking
                effectiveFrom                    = $timestampFormatted
                effectiveTo                      = $null

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
                    -BlobName $principalsBlobName `
                    -Content $usersJsonL.ToString() `
                    -AccessToken $storageToken `
                    -MaxRetries 3 `
                    -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($usersJsonL.Length) chars to principals blob (batch $batchNumber)"
                $usersJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Principals blob write failed after retries at batch $batchNumber $_"
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
                -BlobName $principalsBlobName `
                -Content $usersJsonL.ToString() `
                -AccessToken $storageToken `
                -MaxRetries 3 `
                -BaseRetryDelaySeconds 2
            Write-Verbose "Final principals flush: $($usersJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final principals flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Collection complete: $userCount users with embedded auth methods ($authMethodsProcessedCount processed)"
    Write-Verbose "Risk data: $usersAtRiskCount at-risk users (High: $highRiskCount, Medium: $mediumRiskCount, Low: $lowRiskCount)"
    Write-Verbose "License data: $usersWithP2Count with P2, $usersWithE5Count with E5, $unlicensedCount unlicensed"

    # Phase 2b: Log delta-based auth methods optimization
    if (-not $isFullSync -and $changedUserIds.Count -gt 0) {
        Write-Information "[USER-DELTA] Incremental sync: Skipped auth methods for $deltaAuthSkippedCount unchanged users (collected for $authMethodsProcessedCount changed users)" -InformationAction Continue
    }

    # Cleanup
    $usersJsonL.Clear()
    $usersJsonL = $null

    # Create summary (includes embedded auth methods + risk stats)
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
        # Risk stats (embedded - requires P2)
        riskDataAvailable           = $riskDataAvailable
        riskDataError               = $riskDataError
        riskyUsersLoaded            = $riskyUsersCount
        usersAtRiskCount            = $usersAtRiskCount
        highRiskCount               = $highRiskCount
        mediumRiskCount             = $mediumRiskCount
        lowRiskCount                = $lowRiskCount
        # License stats (embedded)
        usersWithP2LicenseCount     = $usersWithP2Count
        usersWithE5LicenseCount     = $usersWithE5Count
        unlicensedUserCount         = $unlicensedCount
        skuLookupCount              = $skuLookup.Count
        blobPath                    = $principalsBlobName
        # Phase 2b: Delta sync stats
        deltaEnabled                = $useDeltaSync
        deltaIsFullSync             = $isFullSync
        deltaChangedUserCount       = $changedUserIds.Count
        deltaAuthSkippedCount       = $deltaAuthSkippedCount
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    # Log performance timing for batch optimization analysis
    $perfTimer.LogSummary("CollectUsers")
    $phaseTiming = $perfTimer.Summary()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success                   = $true
        UserCount                 = $userCount
        AuthMethodsProcessedCount = $authMethodsProcessedCount
        AuthMethodsErrorCount     = $authMethodsErrorCount
        RiskDataAvailable         = $riskDataAvailable
        RiskDataError             = $riskDataError
        RiskyUsersLoaded          = $riskyUsersCount
        UsersAtRiskCount          = $usersAtRiskCount
        UsersWithP2LicenseCount   = $usersWithP2Count
        UsersWithE5LicenseCount   = $usersWithE5Count
        UnlicensedUserCount       = $unlicensedCount
        Data                      = @()
        Summary                   = $summary
        Timestamp                 = $timestamp
        PrincipalsBlobName        = $principalsBlobName
        PhaseTiming               = $phaseTiming
    }
}
catch {
    Write-Error "Unexpected error in CollectUsers: $_"
    return @{
        Success = $false
        Error   = $_.Exception.Message
    }
}
#endregion
