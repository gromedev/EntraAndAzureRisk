<#
.SYNOPSIS
    Collects Intune policies (Compliance + App Protection) for virtual edge derivation
.DESCRIPTION
    V3.5 Consolidated Intune Policy Collector:
    - Compliance Policies (deviceCompliancePolicies API)
    - App Protection Policies / MAM (iosManagedAppProtections, androidManagedAppProtections, etc.)

    APIs:
    - /deviceManagement/deviceCompliancePolicies?$expand=assignments
    - /deviceAppManagement/iosManagedAppProtections?$expand=assignments,apps
    - /deviceAppManagement/androidManagedAppProtections?$expand=assignments,apps
    - /deviceAppManagement/windowsInformationProtectionPolicies?$expand=assignments

    Permissions:
    - DeviceManagementConfiguration.Read.All (Compliance)
    - DeviceManagementApps.Read.All (App Protection)

    Output: policies.jsonl with policyType="compliancePolicy" or "appProtectionPolicy"
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    return @{ Success = $false; Error = "Failed to import module: $($_.Exception.Message)" }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Intune Policies collection (Compliance + App Protection)"

    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get tokens
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        return @{ Success = $false; Error = "Token acquisition failed: $($_.Exception.Message)" }
    }

    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Initialize buffer and stats
    $jsonL = New-Object System.Text.StringBuilder(1048576)
    $stats = @{
        TotalPolicies = 0
        # Compliance policy stats
        CompliancePolicies = 0
        ComplianceWindows = 0
        ComplianceiOS = 0
        ComplianceAndroid = 0
        CompliancemacOS = 0
        # App protection policy stats
        AppProtectionPolicies = 0
        AppProtectioniOS = 0
        AppProtectionAndroid = 0
        AppProtectionWindows = 0
    }

    # Initialize blob
    $policiesBlobName = "$timestamp/$timestamp-policies.jsonl"
    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $policiesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
    }

    #region 1. Collect Compliance Policies
    Write-Verbose "Collecting Compliance Policies..."
    $complianceNextLink = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$expand=assignments"

    while ($complianceNextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $complianceNextLink -AccessToken $graphToken
            $policies = $response.value
            $complianceNextLink = $response.'@odata.nextLink'
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden|permission') {
                Write-Warning "Compliance Policies requires DeviceManagementConfiguration.Read.All permission"
            } else {
                Write-Warning "Failed to retrieve compliance policies: $_"
            }
            break
        }

        if ($policies.Count -eq 0) { break }

        foreach ($policy in $policies) {
            $odataType = $policy.'@odata.type' ?? ''
            $platform = switch -Regex ($odataType) {
                'windows' { 'windows'; $stats.ComplianceWindows++ }
                'ios' { 'iOS'; $stats.ComplianceiOS++ }
                'android' { 'android'; $stats.ComplianceAndroid++ }
                'macOS' { 'macOS'; $stats.CompliancemacOS++ }
                default { 'unknown' }
            }

            # Extract assignments
            $assignments = @()
            foreach ($assignment in $policy.assignments) {
                $target = $assignment.target
                $assignments += @{
                    targetType = $target.'@odata.type' -replace '#microsoft.graph.', ''
                    groupId = $target.groupId ?? $null
                    deviceAndAppManagementAssignmentFilterType = $target.deviceAndAppManagementAssignmentFilterType ?? $null
                }
            }

            $policyObj = @{
                objectId = $policy.id
                policyType = "compliancePolicy"
                displayName = $policy.displayName ?? ""
                description = $policy.description ?? ""
                platform = $platform
                odataType = $odataType
                createdDateTime = $policy.createdDateTime ?? $null
                lastModifiedDateTime = $policy.lastModifiedDateTime ?? $null
                version = $policy.version ?? 0
                assignments = $assignments
                assignmentCount = $assignments.Count
                # Common compliance settings
                passwordRequired = $policy.passwordRequired ?? $null
                passwordMinimumLength = $policy.passwordMinimumLength ?? $null
                storageRequireEncryption = $policy.storageRequireEncryption ?? $null
                securityBlockJailbrokenDevices = $policy.securityBlockJailbrokenDevices ?? $null
                osMinimumVersion = $policy.osMinimumVersion ?? $null
                osMaximumVersion = $policy.osMaximumVersion ?? $null
                collectionTimestamp = $timestampFormatted
            }

            [void]$jsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $stats.CompliancePolicies++
            $stats.TotalPolicies++
        }
    }
    #endregion

    #region 2. Collect App Protection Policies (MAM)
    Write-Verbose "Collecting App Protection Policies (MAM)..."

    $mamEndpoints = @(
        @{ Uri = "https://graph.microsoft.com/beta/deviceAppManagement/iosManagedAppProtections?`$expand=assignments,apps"; Platform = "iOS" },
        @{ Uri = "https://graph.microsoft.com/beta/deviceAppManagement/androidManagedAppProtections?`$expand=assignments,apps"; Platform = "Android" },
        @{ Uri = "https://graph.microsoft.com/beta/deviceAppManagement/windowsInformationProtectionPolicies?`$expand=assignments"; Platform = "Windows" }
    )

    foreach ($endpoint in $mamEndpoints) {
        $nextLink = $endpoint.Uri
        $platform = $endpoint.Platform

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                $policies = $response.value
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                if ($_.Exception.Message -match '403|Forbidden|permission') {
                    Write-Warning "App Protection Policies requires DeviceManagementApps.Read.All permission"
                } else {
                    Write-Warning "Failed to retrieve $platform MAM policies: $_"
                }
                break
            }

            if ($policies.Count -eq 0) { break }

            foreach ($policy in $policies) {
                # Extract assignments
                $assignments = @()
                foreach ($assignment in $policy.assignments) {
                    $target = $assignment.target
                    $assignments += @{
                        targetType = $target.'@odata.type' -replace '#microsoft.graph.', ''
                        groupId = $target.groupId ?? $null
                    }
                }

                # Extract protected apps
                $protectedApps = @()
                foreach ($app in $policy.apps) {
                    $protectedApps += @{
                        mobileAppIdentifier = $app.mobileAppIdentifier ?? $null
                    }
                }

                $policyObj = @{
                    objectId = $policy.id
                    policyType = "appProtectionPolicy"
                    displayName = $policy.displayName ?? ""
                    description = $policy.description ?? ""
                    platform = $platform
                    createdDateTime = $policy.createdDateTime ?? $null
                    lastModifiedDateTime = $policy.lastModifiedDateTime ?? $null
                    version = $policy.version ?? ""
                    assignments = $assignments
                    assignmentCount = $assignments.Count
                    protectedApps = $protectedApps
                    protectedAppCount = $protectedApps.Count
                    # MAM settings
                    pinRequired = $policy.pinRequired ?? $null
                    minimumPinLength = $policy.minimumPinLength ?? $null
                    managedBrowser = $policy.managedBrowser ?? $null
                    dataBackupBlocked = $policy.dataBackupBlocked ?? $null
                    deviceComplianceRequired = $policy.deviceComplianceRequired ?? $null
                    saveAsBlocked = $policy.saveAsBlocked ?? $null
                    periodOfflineBeforeAccessCheck = $policy.periodOfflineBeforeAccessCheck ?? $null
                    periodOnlineBeforeAccessCheck = $policy.periodOnlineBeforeAccessCheck ?? $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$jsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
                $stats.AppProtectionPolicies++
                $stats.TotalPolicies++

                switch ($platform) {
                    'iOS' { $stats.AppProtectioniOS++ }
                    'Android' { $stats.AppProtectionAndroid++ }
                    'Windows' { $stats.AppProtectionWindows++ }
                }
            }
        }
    }
    #endregion

    # Flush to blob
    if ($jsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $policiesBlobName `
                            -Content $jsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
        }
        catch {
            Write-Error "Blob write failed: $_"
            throw
        }
    }

    Write-Verbose "Intune Policies collection complete: $($stats.TotalPolicies) policies"
    Write-Verbose "  Compliance: $($stats.CompliancePolicies) (Win: $($stats.ComplianceWindows), iOS: $($stats.ComplianceiOS), Android: $($stats.ComplianceAndroid))"
    Write-Verbose "  App Protection: $($stats.AppProtectionPolicies) (iOS: $($stats.AppProtectioniOS), Android: $($stats.AppProtectionAndroid), Win: $($stats.AppProtectionWindows))"

    return @{
        Success = $true
        PolicyCount = $stats.TotalPolicies
        CompliancePolicyCount = $stats.CompliancePolicies
        AppProtectionPolicyCount = $stats.AppProtectionPolicies
        Statistics = $stats
        BlobName = $policiesBlobName
        Timestamp = $timestamp
    }
}
catch {
    Write-Error "CollectIntunePolicies failed: $_"
    return @{ Success = $false; Error = $_.Exception.Message }
}
#endregion
