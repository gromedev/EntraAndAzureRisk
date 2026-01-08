<#
.SYNOPSIS
    Combined collector for ALL policy types: CA policies, role management policies, and named locations
.DESCRIPTION
    Consolidates policy collections into a single activity function:
    1. Conditional Access policies (policyType = "conditionalAccess")
    2. Role management policies (policyType = "roleManagement")
    3. Role management policy assignments (policyType = "roleManagementAssignment")
    4. Named locations for CA (policyType = "namedLocation") - IP ranges, country locations

    All output goes to a single policies.jsonl file with policyType discriminator.
    This enables unified indexing to the 'policies' container.
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
        NamedLocations = @{ Success = $false; Count = 0 }
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

    #region 2. Collect Role Management Policies
    Write-Verbose "=== Phase 2: Collecting role management policies ==="

    $rmPolicyCount = 0

    try {
        $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=rules,effectiveRules&`$top=$batchSize"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($policy in $response.value) {
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
    $overallSuccess = $results.ConditionalAccess.Success -or $results.RoleManagementPolicies.Success -or $results.RoleManagementAssignments.Success -or $results.NamedLocations.Success
    $totalCount = $results.ConditionalAccess.Count + $results.RoleManagementPolicies.Count + $results.RoleManagementAssignments.Count + $results.NamedLocations.Count

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
        NamedLocationCount = $results.NamedLocations.Count

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
            }
            namedLocations = @{
                total = $results.NamedLocations.Count
                ipLocations = $results.NamedLocations.IpLocationCount
                countryLocations = $results.NamedLocations.CountryLocationCount
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
