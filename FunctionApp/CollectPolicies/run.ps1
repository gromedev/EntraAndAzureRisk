<#
.SYNOPSIS
    Combined collector for ALL policy types: CA policies, role management policies, security policies, and named locations
.DESCRIPTION
    Consolidates policy collections into a single activity function:
    1. Conditional Access policies (policyType = "conditionalAccess")
    2. Role management policies (policyType = "roleManagement")
    3. Role management policy assignments (policyType = "roleManagementAssignment")
    3b. PIM Group policies (policyType = "pimGroupPolicy")
    4. Named locations for CA (policyType = "namedLocation") - IP ranges, country locations
    5. Authentication Methods Policy (policyType = "authenticationMethodsPolicy") - tenant-wide auth methods
    6. Security Defaults Policy (policyType = "securityDefaults") - baseline MFA settings
    7. Authorization Policy (policyType = "authorizationPolicy") - guest/user permissions

    All output goes to a single policies.jsonl file with policyType discriminator.
    This enables unified indexing to the 'policies' container.

    Permissions Required:
    - Policy.Read.All (for most policies)
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
    Write-Verbose "Starting combined policies collection"

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

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $writeThreshold = 500000  # 500KB before flush

    # Results tracking
    $results = @{
        ConditionalAccess = @{ Success = $false; Count = 0 }
        RoleManagementPolicies = @{ Success = $false; Count = 0 }
        RoleManagementAssignments = @{ Success = $false; Count = 0 }
        PimGroupPolicies = @{ Success = $false; Count = 0 }
        NamedLocations = @{ Success = $false; Count = 0 }
        # Phase 1 Security Policies (new)
        AuthenticationMethods = @{ Success = $false; Count = 0 }
        SecurityDefaults = @{ Success = $false; Count = 0 }
        Authorization = @{ Success = $false; Count = 0 }
    }

    # Initialize unified blob
    $policiesBlobName = "$timestamp/$timestamp-policies.jsonl"
    Write-Verbose "Initializing append blob: $policiesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $policiesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    $policiesJsonL = New-Object System.Text.StringBuilder(1048576)

    #region 1. Collect Conditional Access Policies
    Write-Verbose "=== Phase 1: Collecting Conditional Access policies ==="

    $caCount = 0
    $caEnabledCount = 0
    $caDisabledCount = 0
    $caReportOnlyCount = 0

    try {
        $nextLink = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($policy in $response.value) {
                    $policyObj = @{
                        id = $policy.id ?? ""
                        objectId = $policy.id ?? ""
                        policyType = "conditionalAccess"
                        displayName = $policy.displayName ?? ""
                        state = $policy.state ?? ""
                        createdDateTime = $policy.createdDateTime ?? $null
                        modifiedDateTime = $policy.modifiedDateTime ?? $null
                        conditions = @{
                            users = $policy.conditions.users ?? @{}
                            applications = $policy.conditions.applications ?? @{}
                            clientAppTypes = $policy.conditions.clientAppTypes ?? @()
                            platforms = $policy.conditions.platforms ?? @{}
                            locations = $policy.conditions.locations ?? @{}
                            signInRiskLevels = $policy.conditions.signInRiskLevels ?? @()
                            userRiskLevels = $policy.conditions.userRiskLevels ?? @()
                        }
                        grantControls = @{
                            operator = $policy.grantControls.operator ?? ""
                            builtInControls = $policy.grantControls.builtInControls ?? @()
                            customAuthenticationFactors = $policy.grantControls.customAuthenticationFactors ?? @()
                            termsOfUse = $policy.grantControls.termsOfUse ?? @()
                        }
                        sessionControls = @{
                            applicationEnforcedRestrictions = $policy.sessionControls.applicationEnforcedRestrictions ?? $null
                            cloudAppSecurity = $policy.sessionControls.cloudAppSecurity ?? $null
                            persistentBrowser = $policy.sessionControls.persistentBrowser ?? $null
                            signInFrequency = $policy.sessionControls.signInFrequency ?? $null
                        }
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                    $caCount++

                    switch ($policyObj.state) {
                        'enabled' { $caEnabledCount++ }
                        'disabled' { $caDisabledCount++ }
                        'enabledForReportingButNotEnforced' { $caReportOnlyCount++ }
                    }
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "CA policies batch error: $_"
                break
            }
        }

        $results.ConditionalAccess = @{
            Success = $true
            Count = $caCount
            EnabledCount = $caEnabledCount
            DisabledCount = $caDisabledCount
            ReportOnlyCount = $caReportOnlyCount
        }
        Write-Verbose "CA policies complete: $caCount policies ($caEnabledCount enabled, $caDisabledCount disabled, $caReportOnlyCount report-only)"
    }
    catch {
        Write-Warning "CA policies collection failed: $_"
        $results.ConditionalAccess.Error = $_.Exception.Message
    }

    # Periodic flush
    if ($policiesJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($policiesJsonL.Length) characters after CA policies"
            $policiesJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }
    #endregion

    #region 2. Collect Role Management Policies (Directory Roles PIM)
    Write-Verbose "=== Phase 2: Collecting role management policies (Directory Roles) ==="

    $rmPolicyCount = 0

    # Helper function to extract key settings from policy rules
    function Get-PolicySettings {
        param($Rules)
        $settings = @{
            # Approval settings
            isApprovalRequired = $false
            approvalMode = $null
            primaryApprovers = @()
            # Expiration settings
            maxActivationDuration = $null
            maxEligibilityDuration = $null
            maxAssignmentDuration = $null
            isEligibilityExpirationRequired = $false
            isAssignmentExpirationRequired = $false
            # Enablement settings (what's required for activation)
            requiresJustification = $false
            requiresMfa = $false
            requiresTicketInfo = $false
        }

        foreach ($rule in $Rules) {
            $ruleType = $rule.'@odata.type'
            $ruleId = $rule.id ?? ''

            switch -Regex ($ruleType) {
                'ApprovalRule' {
                    $settings.isApprovalRequired = $rule.setting.isApprovalRequired ?? $false
                    $settings.approvalMode = $rule.setting.approvalMode ?? $null
                    if ($rule.setting.approvalStages -and $rule.setting.approvalStages.Count -gt 0) {
                        $settings.primaryApprovers = @($rule.setting.approvalStages[0].primaryApprovers | ForEach-Object {
                            @{
                                type = $_.'@odata.type' -replace '#microsoft.graph.', ''
                                id = $_.id ?? $null
                                description = $_.description ?? $null
                            }
                        })
                    }
                }
                'ExpirationRule' {
                    if ($ruleId -match 'Eligibility') {
                        $settings.maxEligibilityDuration = $rule.maximumDuration ?? $null
                        $settings.isEligibilityExpirationRequired = $rule.isExpirationRequired ?? $false
                    }
                    elseif ($ruleId -match 'Assignment' -and $ruleId -match 'EndUser') {
                        # This is the activation duration
                        $settings.maxActivationDuration = $rule.maximumDuration ?? $null
                    }
                    elseif ($ruleId -match 'Assignment' -and $ruleId -match 'Admin') {
                        $settings.maxAssignmentDuration = $rule.maximumDuration ?? $null
                        $settings.isAssignmentExpirationRequired = $rule.isExpirationRequired ?? $false
                    }
                }
                'EnablementRule' {
                    if ($ruleId -match 'EndUser') {
                        $enabledRules = $rule.enabledRules ?? @()
                        $settings.requiresJustification = 'Justification' -in $enabledRules
                        $settings.requiresMfa = 'MultiFactorAuthentication' -in $enabledRules
                        $settings.requiresTicketInfo = 'Ticketing' -in $enabledRules
                    }
                }
            }
        }
        return $settings
    }

    try {
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=rules,effectiveRules&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($policy in $response.value) {
                    # Extract key settings for easier querying
                    $policySettings = Get-PolicySettings -Rules $policy.rules

                    $policyObj = @{
                        id = $policy.id ?? ""
                        objectId = $policy.id ?? ""
                        policyType = "roleManagement"
                        displayName = $policy.displayName ?? ""
                        description = $policy.description ?? ""
                        isOrganizationDefault = $policy.isOrganizationDefault ?? $false
                        scope = $policy.scope ?? ""
                        scopeId = $policy.scopeId ?? ""
                        scopeType = $policy.scopeType ?? ""
                        # Extracted key settings for dashboard display
                        isApprovalRequired = $policySettings.isApprovalRequired
                        approvalMode = $policySettings.approvalMode
                        primaryApprovers = $policySettings.primaryApprovers
                        maxActivationDuration = $policySettings.maxActivationDuration
                        maxEligibilityDuration = $policySettings.maxEligibilityDuration
                        maxAssignmentDuration = $policySettings.maxAssignmentDuration
                        isEligibilityExpirationRequired = $policySettings.isEligibilityExpirationRequired
                        isAssignmentExpirationRequired = $policySettings.isAssignmentExpirationRequired
                        requiresJustification = $policySettings.requiresJustification
                        requiresMfa = $policySettings.requiresMfa
                        requiresTicketInfo = $policySettings.requiresTicketInfo
                        # Full rules for deep analysis
                        rules = $policy.rules ?? @()
                        effectiveRules = $policy.effectiveRules ?? @()
                        lastModifiedDateTime = $policy.lastModifiedDateTime ?? ""
                        lastModifiedBy = $policy.lastModifiedBy ?? @{}
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                    $rmPolicyCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "Role management policies batch error: $_"
                break
            }
        }

        $results.RoleManagementPolicies = @{
            Success = $true
            Count = $rmPolicyCount
        }
        Write-Verbose "Role management policies complete: $rmPolicyCount policies"
    }
    catch {
        Write-Warning "Role management policies collection failed: $_"
        $results.RoleManagementPolicies.Error = $_.Exception.Message
    }

    # Periodic flush
    if ($policiesJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($policiesJsonL.Length) characters after role management policies"
            $policiesJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }
    #endregion

    #region 3. Collect Role Management Policy Assignments
    Write-Verbose "=== Phase 3: Collecting role management policy assignments ==="

    $rmAssignmentCount = 0

    try {
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($assignment in $response.value) {
                    $assignmentObj = @{
                        id = $assignment.id ?? ""
                        objectId = $assignment.id ?? ""
                        policyType = "roleManagementAssignment"
                        policyId = $assignment.policyId ?? ""
                        roleDefinitionId = $assignment.roleDefinitionId ?? ""
                        scope = $assignment.scope ?? ""
                        scopeId = $assignment.scopeId ?? ""
                        scopeType = $assignment.scopeType ?? ""
                        policyDisplayName = $assignment.policy.displayName ?? ""
                        policyIsOrganizationDefault = $assignment.policy.isOrganizationDefault ?? $false
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$policiesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
                    $rmAssignmentCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "Role management assignments batch error: $_"
                break
            }
        }

        $results.RoleManagementAssignments = @{
            Success = $true
            Count = $rmAssignmentCount
        }
        Write-Verbose "Role management assignments complete: $rmAssignmentCount assignments"
    }
    catch {
        Write-Warning "Role management assignments collection failed: $_"
        $results.RoleManagementAssignments.Error = $_.Exception.Message
    }
    #endregion

    # Periodic flush
    if ($policiesJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($policiesJsonL.Length) characters after role management assignments"
            $policiesJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }

    #region 3b. Collect PIM Group Policies (requires RoleManagementPolicy.Read.AzureADGroup permission)
    Write-Verbose "=== Phase 3b: Collecting PIM Group policies ==="

    $pimGroupPolicyCount = 0

    try {
        # This requires RoleManagementPolicy.Read.AzureADGroup permission
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies?`$filter=scopeType eq 'Group'&`$expand=rules,effectiveRules&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($policy in $response.value) {
                    # Extract key settings for easier querying
                    $policySettings = Get-PolicySettings -Rules $policy.rules

                    $policyObj = @{
                        id = $policy.id ?? ""
                        objectId = $policy.id ?? ""
                        policyType = "pimGroupPolicy"
                        displayName = $policy.displayName ?? ""
                        description = $policy.description ?? ""
                        isOrganizationDefault = $policy.isOrganizationDefault ?? $false
                        scope = $policy.scope ?? ""
                        scopeId = $policy.scopeId ?? ""  # This is the group ID
                        scopeType = $policy.scopeType ?? ""
                        # Extracted key settings for dashboard display
                        isApprovalRequired = $policySettings.isApprovalRequired
                        approvalMode = $policySettings.approvalMode
                        primaryApprovers = $policySettings.primaryApprovers
                        maxActivationDuration = $policySettings.maxActivationDuration
                        maxEligibilityDuration = $policySettings.maxEligibilityDuration
                        maxAssignmentDuration = $policySettings.maxAssignmentDuration
                        isEligibilityExpirationRequired = $policySettings.isEligibilityExpirationRequired
                        isAssignmentExpirationRequired = $policySettings.isAssignmentExpirationRequired
                        requiresJustification = $policySettings.requiresJustification
                        requiresMfa = $policySettings.requiresMfa
                        requiresTicketInfo = $policySettings.requiresTicketInfo
                        # Full rules for deep analysis
                        rules = $policy.rules ?? @()
                        effectiveRules = $policy.effectiveRules ?? @()
                        lastModifiedDateTime = $policy.lastModifiedDateTime ?? ""
                        lastModifiedBy = $policy.lastModifiedBy ?? @{}
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                    $pimGroupPolicyCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                if ($_.Exception.Message -match '403|Forbidden|permission|PermissionScopeNotGranted') {
                    Write-Warning "PIM Group policies requires RoleManagementPolicy.Read.AzureADGroup permission - skipping"
                } else {
                    Write-Warning "PIM Group policies batch error: $_"
                }
                break
            }
        }

        $results.PimGroupPolicies = @{
            Success = $pimGroupPolicyCount -gt 0
            Count = $pimGroupPolicyCount
        }
        if ($pimGroupPolicyCount -gt 0) {
            Write-Verbose "PIM Group policies complete: $pimGroupPolicyCount policies"
        }
    }
    catch {
        Write-Warning "PIM Group policies collection failed: $_"
        $results.PimGroupPolicies = @{ Success = $false; Count = 0; Error = $_.Exception.Message }
    }
    #endregion

    # Periodic flush
    if ($policiesJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($policiesJsonL.Length) characters after PIM Group policies"
            $policiesJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }

    #region 4. Collect Named Locations (used by CA policies for location conditions)
    Write-Verbose "=== Phase 4: Collecting named locations ==="

    $namedLocationCount = 0
    $ipLocationCount = 0
    $countryLocationCount = 0

    try {
        $nextLink = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations?`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($location in $response.value) {
                    $locationType = $location.'@odata.type' -replace '#microsoft.graph.', ''

                    $locationObj = @{
                        id = $location.id ?? ""
                        objectId = $location.id ?? ""
                        policyType = "namedLocation"
                        locationType = $locationType
                        displayName = $location.displayName ?? ""
                        createdDateTime = $location.createdDateTime ?? $null
                        modifiedDateTime = $location.modifiedDateTime ?? $null
                        collectionTimestamp = $timestampFormatted
                    }

                    # Add type-specific properties
                    if ($locationType -eq 'ipNamedLocation') {
                        $locationObj.isTrusted = $location.isTrusted ?? $false
                        $locationObj.ipRanges = @($location.ipRanges | ForEach-Object {
                            @{
                                cidrAddress = $_.'@odata.type' -match 'iPv4' ? $_.cidrAddress : $null
                                cidrAddressV6 = $_.'@odata.type' -match 'iPv6' ? $_.cidrAddress : $null
                                type = $_.'@odata.type' -replace '#microsoft.graph.', ''
                            }
                        })
                        $locationObj.ipRangeCount = $location.ipRanges.Count
                        $ipLocationCount++
                    }
                    elseif ($locationType -eq 'countryNamedLocation') {
                        $locationObj.countriesAndRegions = $location.countriesAndRegions ?? @()
                        $locationObj.countryLookupMethod = $location.countryLookupMethod ?? ""
                        $locationObj.includeUnknownCountriesAndRegions = $location.includeUnknownCountriesAndRegions ?? $false
                        $countryLocationCount++
                    }

                    [void]$policiesJsonL.AppendLine(($locationObj | ConvertTo-Json -Compress -Depth 10))
                    $namedLocationCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "Named locations batch error: $_"
                break
            }
        }

        $results.NamedLocations = @{
            Success = $true
            Count = $namedLocationCount
            IpLocationCount = $ipLocationCount
            CountryLocationCount = $countryLocationCount
        }
        Write-Verbose "Named locations complete: $namedLocationCount locations ($ipLocationCount IP-based, $countryLocationCount country-based)"
    }
    catch {
        Write-Warning "Named locations collection failed: $_"
        $results.NamedLocations.Error = $_.Exception.Message
    }
    #endregion

    # Periodic flush before Phase 5
    if ($policiesJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($policiesJsonL.Length) characters after named locations"
            $policiesJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }

    #region 5. Collect Authentication Methods Policy (tenant-wide auth methods configuration)
    Write-Verbose "=== Phase 5: Collecting Authentication Methods Policy ==="

    $authMethodsCount = 0

    try {
        # Get the tenant-wide authentication methods policy
        $authMethodsUri = "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy"

        try {
            $authMethodsPolicy = Invoke-GraphWithRetry -Uri $authMethodsUri -AccessToken $graphToken

            # Extract authentication method configurations
            $methodConfigs = @()
            foreach ($config in $authMethodsPolicy.authenticationMethodConfigurations) {
                $methodConfigs += @{
                    method = $config.'@odata.type' -replace '#microsoft.graph.', '' -replace 'AuthenticationMethodConfiguration', ''
                    id = $config.id ?? $null
                    state = $config.state ?? 'disabled'
                    includeTargets = $config.includeTargets ?? @()
                    excludeTargets = $config.excludeTargets ?? @()
                }
            }

            $policyObj = @{
                id = $authMethodsPolicy.id ?? "authenticationMethodsPolicy"
                objectId = $authMethodsPolicy.id ?? "authenticationMethodsPolicy"
                policyType = "authenticationMethodsPolicy"
                displayName = $authMethodsPolicy.displayName ?? "Authentication Methods Policy"
                description = $authMethodsPolicy.description ?? ""
                policyVersion = $authMethodsPolicy.policyVersion ?? ""
                policyMigrationState = $authMethodsPolicy.policyMigrationState ?? ""
                reconfirmationInDays = $authMethodsPolicy.reconfirmationInDays ?? $null
                registrationEnforcement = $authMethodsPolicy.registrationEnforcement ?? @{}
                reportSuspiciousActivitySettings = $authMethodsPolicy.reportSuspiciousActivitySettings ?? @{}
                systemCredentialPreferences = $authMethodsPolicy.systemCredentialPreferences ?? @{}
                lastModifiedDateTime = $authMethodsPolicy.lastModifiedDateTime ?? $null
                # Extracted method configurations for easier querying
                authenticationMethodConfigurations = $methodConfigs
                methodConfigurationCount = $methodConfigs.Count
                # Individual method states for dashboard filtering
                microsoftAuthenticatorEnabled = ($methodConfigs | Where-Object { $_.method -eq 'microsoftAuthenticator' -and $_.state -eq 'enabled' }).Count -gt 0
                fido2Enabled = ($methodConfigs | Where-Object { $_.method -eq 'fido2' -and $_.state -eq 'enabled' }).Count -gt 0
                smsEnabled = ($methodConfigs | Where-Object { $_.method -eq 'sms' -and $_.state -eq 'enabled' }).Count -gt 0
                emailEnabled = ($methodConfigs | Where-Object { $_.method -eq 'email' -and $_.state -eq 'enabled' }).Count -gt 0
                temporaryAccessPassEnabled = ($methodConfigs | Where-Object { $_.method -eq 'temporaryAccessPass' -and $_.state -eq 'enabled' }).Count -gt 0
                softwareOathEnabled = ($methodConfigs | Where-Object { $_.method -eq 'softwareOath' -and $_.state -eq 'enabled' }).Count -gt 0
                voiceEnabled = ($methodConfigs | Where-Object { $_.method -eq 'voice' -and $_.state -eq 'enabled' }).Count -gt 0
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $authMethodsCount++

            $results.AuthenticationMethods = @{
                Success = $true
                Count = $authMethodsCount
                MethodConfigurationCount = $methodConfigs.Count
            }
            Write-Verbose "Authentication Methods Policy complete: $authMethodsCount policy with $($methodConfigs.Count) method configurations"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Authentication Methods Policy requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve authentication methods policy: $_"
            }
            $results.AuthenticationMethods.Error = $_.Exception.Message
        }
    }
    catch {
        Write-Warning "Authentication Methods Policy collection failed: $_"
        $results.AuthenticationMethods.Error = $_.Exception.Message
    }
    #endregion

    #region 6. Collect Security Defaults Policy (baseline MFA)
    Write-Verbose "=== Phase 6: Collecting Security Defaults Policy ==="

    $securityDefaultsCount = 0

    try {
        $securityDefaultsUri = "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"

        try {
            $securityDefaultsPolicy = Invoke-GraphWithRetry -Uri $securityDefaultsUri -AccessToken $graphToken

            $policyObj = @{
                id = $securityDefaultsPolicy.id ?? "securityDefaults"
                objectId = $securityDefaultsPolicy.id ?? "securityDefaults"
                policyType = "securityDefaults"
                displayName = $securityDefaultsPolicy.displayName ?? "Security Defaults"
                description = $securityDefaultsPolicy.description ?? ""
                # Key field: whether security defaults are enabled
                isEnabled = $securityDefaultsPolicy.isEnabled ?? $false
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $securityDefaultsCount++

            $results.SecurityDefaults = @{
                Success = $true
                Count = $securityDefaultsCount
                IsEnabled = $securityDefaultsPolicy.isEnabled ?? $false
            }
            Write-Verbose "Security Defaults Policy complete: isEnabled=$($securityDefaultsPolicy.isEnabled)"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Security Defaults Policy requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve security defaults policy: $_"
            }
            $results.SecurityDefaults.Error = $_.Exception.Message
        }
    }
    catch {
        Write-Warning "Security Defaults Policy collection failed: $_"
        $results.SecurityDefaults.Error = $_.Exception.Message
    }
    #endregion

    #region 7. Collect Authorization Policy (guest/user permissions)
    Write-Verbose "=== Phase 7: Collecting Authorization Policy ==="

    $authorizationCount = 0

    try {
        $authorizationUri = "https://graph.microsoft.com/v1.0/policies/authorizationPolicy"

        try {
            $authorizationPolicy = Invoke-GraphWithRetry -Uri $authorizationUri -AccessToken $graphToken

            # Map guest user role GUIDs to human-readable names
            $guestRoleMap = @{
                'a0b1b346-4d3e-4e8b-98f8-753987be4970' = 'Guest User'           # Restricted
                '10dae51f-b6af-4016-8d66-8c2a99b929b3' = 'Member'                # Same as members
                '2af84b1e-32c8-42b7-82bc-daa82404023b' = 'Restricted Guest User' # Most restricted
            }
            $guestRoleId = $authorizationPolicy.guestUserRoleId ?? ''
            $guestRoleName = if ($guestRoleMap[$guestRoleId]) { $guestRoleMap[$guestRoleId] } else { $guestRoleId }

            $policyObj = @{
                id = $authorizationPolicy.id ?? "authorizationPolicy"
                objectId = $authorizationPolicy.id ?? "authorizationPolicy"
                policyType = "authorizationPolicy"
                displayName = $authorizationPolicy.displayName ?? "Authorization Policy"
                description = $authorizationPolicy.description ?? ""
                # Guest access settings
                allowInvitesFrom = $authorizationPolicy.allowInvitesFrom ?? ""
                guestUserRoleId = $guestRoleId
                guestUserRoleName = $guestRoleName
                allowedToSignUpEmailBasedSubscriptions = $authorizationPolicy.allowedToSignUpEmailBasedSubscriptions ?? $null
                allowedToUseSSPR = $authorizationPolicy.allowedToUseSSPR ?? $null
                allowEmailVerifiedUsersToJoinOrganization = $authorizationPolicy.allowEmailVerifiedUsersToJoinOrganization ?? $null
                blockMsolPowerShell = $authorizationPolicy.blockMsolPowerShell ?? $null
                # Default user permissions
                defaultUserRolePermissions = @{
                    allowedToCreateApps = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps ?? $null
                    allowedToCreateSecurityGroups = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateSecurityGroups ?? $null
                    allowedToCreateTenants = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateTenants ?? $null
                    allowedToReadBitlockerKeysForOwnedDevice = $authorizationPolicy.defaultUserRolePermissions.allowedToReadBitlockerKeysForOwnedDevice ?? $null
                    allowedToReadOtherUsers = $authorizationPolicy.defaultUserRolePermissions.allowedToReadOtherUsers ?? $null
                    permissionGrantPoliciesAssigned = $authorizationPolicy.defaultUserRolePermissions.permissionGrantPoliciesAssigned ?? @()
                }
                # Flattened fields for dashboard filtering
                usersCanCreateApps = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps ?? $null
                usersCanCreateGroups = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateSecurityGroups ?? $null
                usersCanCreateTenants = $authorizationPolicy.defaultUserRolePermissions.allowedToCreateTenants ?? $null
                usersCanReadOtherUsers = $authorizationPolicy.defaultUserRolePermissions.allowedToReadOtherUsers ?? $null
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $authorizationCount++

            $results.Authorization = @{
                Success = $true
                Count = $authorizationCount
                GuestRole = $guestRoleName
                AllowInvitesFrom = $authorizationPolicy.allowInvitesFrom ?? ''
            }
            Write-Verbose "Authorization Policy complete: guestRole=$guestRoleName, allowInvitesFrom=$($authorizationPolicy.allowInvitesFrom)"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Authorization Policy requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve authorization policy: $_"
            }
            $results.Authorization.Error = $_.Exception.Message
        }
    }
    catch {
        Write-Warning "Authorization Policy collection failed: $_"
        $results.Authorization.Error = $_.Exception.Message
    }
    #endregion

    #region 8. Collect Cross-Tenant Access Policy (B2B collaboration settings)
    Write-Verbose "=== Phase 8: Collecting Cross-Tenant Access Policy ==="

    $crossTenantCount = 0

    try {
        $crossTenantUri = "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy"

        try {
            $crossTenantPolicy = Invoke-GraphWithRetry -Uri $crossTenantUri -AccessToken $graphToken

            $policyObj = @{
                id = $crossTenantPolicy.displayName ?? "crossTenantAccessPolicy"
                objectId = "crossTenantAccessPolicy"
                policyType = "crossTenantAccessPolicy"
                displayName = $crossTenantPolicy.displayName ?? "Cross-Tenant Access Policy"
                allowedCloudEndpoints = $crossTenantPolicy.allowedCloudEndpoints ?? @()
                # Default settings for external collaboration
                default = @{
                    b2bCollaborationInbound = $crossTenantPolicy.default.b2bCollaborationInbound ?? @{}
                    b2bCollaborationOutbound = $crossTenantPolicy.default.b2bCollaborationOutbound ?? @{}
                    b2bDirectConnectInbound = $crossTenantPolicy.default.b2bDirectConnectInbound ?? @{}
                    b2bDirectConnectOutbound = $crossTenantPolicy.default.b2bDirectConnectOutbound ?? @{}
                    inboundTrust = $crossTenantPolicy.default.inboundTrust ?? @{}
                    tenantRestrictions = $crossTenantPolicy.default.tenantRestrictions ?? @{}
                }
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $crossTenantCount++

            $results.CrossTenantAccess = @{
                Success = $true
                Count = $crossTenantCount
            }
            Write-Verbose "Cross-Tenant Access Policy complete: $crossTenantCount policy"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Cross-Tenant Access Policy requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve cross-tenant access policy: $_"
            }
            $results.CrossTenantAccess = @{ Success = $false; Error = $_.Exception.Message }
        }
    }
    catch {
        Write-Warning "Cross-Tenant Access Policy collection failed: $_"
        $results.CrossTenantAccess = @{ Success = $false; Error = $_.Exception.Message }
    }
    #endregion

    #region 9. Collect Permission Grant Policies (OAuth consent controls)
    Write-Verbose "=== Phase 9: Collecting Permission Grant Policies ==="

    $permissionGrantCount = 0

    try {
        $permGrantUri = "https://graph.microsoft.com/v1.0/policies/permissionGrantPolicies"

        try {
            $permGrantResponse = Invoke-GraphWithRetry -Uri $permGrantUri -AccessToken $graphToken

            foreach ($policy in $permGrantResponse.value) {
                $policyObj = @{
                    id = $policy.id
                    objectId = $policy.id
                    policyType = "permissionGrantPolicy"
                    displayName = $policy.displayName ?? ""
                    description = $policy.description ?? ""
                    # Include/exclude conditions
                    includes = $policy.includes ?? @()
                    excludes = $policy.excludes ?? @()
                    includeCount = ($policy.includes ?? @()).Count
                    excludeCount = ($policy.excludes ?? @()).Count
                    collectionTimestamp = $timestampFormatted
                }

                [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                $permissionGrantCount++
            }

            $results.PermissionGrant = @{
                Success = $true
                Count = $permissionGrantCount
            }
            Write-Verbose "Permission Grant Policies complete: $permissionGrantCount policies"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Permission Grant Policies requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve permission grant policies: $_"
            }
            $results.PermissionGrant = @{ Success = $false; Error = $_.Exception.Message }
        }
    }
    catch {
        Write-Warning "Permission Grant Policies collection failed: $_"
        $results.PermissionGrant = @{ Success = $false; Error = $_.Exception.Message }
    }
    #endregion

    #region 10. Collect Admin Consent Request Policy
    Write-Verbose "=== Phase 10: Collecting Admin Consent Request Policy ==="

    $adminConsentCount = 0

    try {
        $adminConsentUri = "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"

        try {
            $adminConsentPolicy = Invoke-GraphWithRetry -Uri $adminConsentUri -AccessToken $graphToken

            $policyObj = @{
                id = "adminConsentRequestPolicy"
                objectId = "adminConsentRequestPolicy"
                policyType = "adminConsentRequestPolicy"
                displayName = "Admin Consent Request Policy"
                isEnabled = $adminConsentPolicy.isEnabled ?? $false
                notifyReviewers = $adminConsentPolicy.notifyReviewers ?? $false
                remindersEnabled = $adminConsentPolicy.remindersEnabled ?? $false
                requestDurationInDays = $adminConsentPolicy.requestDurationInDays ?? 0
                reviewers = $adminConsentPolicy.reviewers ?? @()
                reviewerCount = ($adminConsentPolicy.reviewers ?? @()).Count
                version = $adminConsentPolicy.version ?? 0
                collectionTimestamp = $timestampFormatted
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $adminConsentCount++

            $results.AdminConsentRequest = @{
                Success = $true
                Count = $adminConsentCount
                IsEnabled = $adminConsentPolicy.isEnabled ?? $false
            }
            Write-Verbose "Admin Consent Request Policy complete: isEnabled=$($adminConsentPolicy.isEnabled)"
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Admin Consent Request Policy requires Policy.Read.All permission - skipping"
            } else {
                Write-Warning "Failed to retrieve admin consent request policy: $_"
            }
            $results.AdminConsentRequest = @{ Success = $false; Error = $_.Exception.Message }
        }
    }
    catch {
        Write-Warning "Admin Consent Request Policy collection failed: $_"
        $results.AdminConsentRequest = @{ Success = $false; Error = $_.Exception.Message }
    }
    #endregion

    #region Final Flush
    if ($policiesJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Final flush: $($policiesJsonL.Length) characters written"
        }
        catch {
            Write-Error "Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }
    #endregion

    # Cleanup
    $policiesJsonL.Clear()
    $policiesJsonL = $null

    # Garbage collection
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    # Determine overall success
    $overallSuccess = $results.ConditionalAccess.Success -or $results.RoleManagementPolicies.Success -or $results.RoleManagementAssignments.Success -or $results.NamedLocations.Success -or $results.AuthenticationMethods.Success -or $results.SecurityDefaults.Success -or $results.Authorization.Success -or $results.CrossTenantAccess.Success -or $results.PermissionGrant.Success -or $results.AdminConsentRequest.Success
    $pimGroupCount = if ($results.PimGroupPolicies) { $results.PimGroupPolicies.Count } else { 0 }
    $authMethodsCount = if ($results.AuthenticationMethods) { $results.AuthenticationMethods.Count } else { 0 }
    $securityDefaultsCount = if ($results.SecurityDefaults) { $results.SecurityDefaults.Count } else { 0 }
    $authorizationCount = if ($results.Authorization) { $results.Authorization.Count } else { 0 }
    # Phase 2-3: B2B, Consent policies
    $crossTenantCount = if ($results.CrossTenantAccess) { $results.CrossTenantAccess.Count } else { 0 }
    $permissionGrantCount = if ($results.PermissionGrant) { $results.PermissionGrant.Count } else { 0 }
    $adminConsentCount = if ($results.AdminConsentRequest) { $results.AdminConsentRequest.Count } else { 0 }
    $totalCount = $results.ConditionalAccess.Count + $results.RoleManagementPolicies.Count + $results.RoleManagementAssignments.Count + $results.NamedLocations.Count + $pimGroupCount + $authMethodsCount + $securityDefaultsCount + $authorizationCount + $crossTenantCount + $permissionGrantCount + $adminConsentCount

    Write-Verbose "Combined policies collection complete: $totalCount total policies"

    return @{
        Success = $overallSuccess
        Timestamp = $timestamp
        BlobName = $policiesBlobName
        PolicyCount = $totalCount

        # Detailed counts
        ConditionalAccessCount = $results.ConditionalAccess.Count
        RoleManagementPolicyCount = $results.RoleManagementPolicies.Count
        RoleManagementAssignmentCount = $results.RoleManagementAssignments.Count
        PimGroupPolicyCount = $pimGroupCount
        NamedLocationCount = $results.NamedLocations.Count
        # Phase 1 Security Policies
        AuthenticationMethodsPolicyCount = $authMethodsCount
        SecurityDefaultsPolicyCount = $securityDefaultsCount
        AuthorizationPolicyCount = $authorizationCount
        # Phase 2-3: B2B, Consent policies
        CrossTenantAccessPolicyCount = $crossTenantCount
        PermissionGrantPolicyCount = $permissionGrantCount
        AdminConsentRequestPolicyCount = $adminConsentCount

        # Detailed results
        Results = $results

        Summary = @{
            timestamp = $timestampFormatted
            totalCount = $totalCount
            conditionalAccess = @{
                total = $results.ConditionalAccess.Count
                enabled = $results.ConditionalAccess.EnabledCount
                disabled = $results.ConditionalAccess.DisabledCount
                reportOnly = $results.ConditionalAccess.ReportOnlyCount
            }
            roleManagement = @{
                policies = $results.RoleManagementPolicies.Count
                assignments = $results.RoleManagementAssignments.Count
                pimGroupPolicies = $pimGroupCount
            }
            namedLocations = @{
                total = $results.NamedLocations.Count
                ipLocations = $results.NamedLocations.IpLocationCount
                countryLocations = $results.NamedLocations.CountryLocationCount
            }
            securityPolicies = @{
                authenticationMethods = $authMethodsCount
                securityDefaults = $securityDefaultsCount
                authorization = $authorizationCount
                securityDefaultsEnabled = $results.SecurityDefaults.IsEnabled
                guestUserRole = $results.Authorization.GuestRole
            }
            # Phase 2-3: B2B, Consent policies
            b2bAndConsent = @{
                crossTenantAccess = $crossTenantCount
                permissionGrant = $permissionGrantCount
                adminConsentRequest = $adminConsentCount
                adminConsentEnabled = $results.AdminConsentRequest.IsEnabled
            }
        }
    }
}
catch {
    Write-Error "Combined policies collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
