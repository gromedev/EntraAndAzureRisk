<#
.SYNOPSIS
    Combined collector for ALL event types: sign-in logs and directory audits
.DESCRIPTION
    Consolidates event collections into a single activity function:
    1. Sign-in logs - failed/risky (eventType = "signIn")
    2. Directory audits (eventType = "audit")

    All output goes to a single events.jsonl file with eventType discriminator.
    This enables unified indexing to the 'events' container.

    NOTE: This is EVENT-based data, not entity-based.
    Each run appends new events; no delta detection is used.
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
    Write-Verbose "Starting combined events collection"

    # V3: Use shared timestamp from orchestrator (critical for unified blob files)
    $now = (Get-Date).ToUniversalTime()
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Determine time window for collection
    $defaultHoursBack = if ($env:EVENT_LOGS_HOURS_BACK) { [int]$env:EVENT_LOGS_HOURS_BACK } else { 24 }
    $sinceDateTime = if ($ActivityInput.LastCollectionTimestamp) {
        [DateTime]$ActivityInput.LastCollectionTimestamp
    } else {
        $now.AddHours(-$defaultHoursBack)
    }
    $sinceFormatted = $sinceDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collecting events since: $sinceFormatted"

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
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $writeThreshold = 1000000  # 1MB before flush

    # Results tracking
    $results = @{
        SignIns = @{ Success = $false; Count = 0 }
        Audits = @{ Success = $false; Count = 0 }
    }

    # Initialize unified blob
    $eventsBlobName = "$timestamp/$timestamp-events.jsonl"
    Write-Verbose "Initializing append blob: $eventsBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $eventsBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    $eventsJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial capacity

    #region 1. Collect Sign-In Logs (Failed/Risky)
    Write-Verbose "=== Phase 1: Collecting sign-in logs ==="

    $signInCount = 0
    $failedCount = 0
    $riskyCount = 0
    $mfaFailedCount = 0
    $interactiveCount = 0
    $nonInteractiveCount = 0

    try {
        # Filter: failed sign-ins (errorCode != 0) OR risky sign-ins (riskLevelAggregated != none)
        $filter = "createdDateTime ge $sinceFormatted and (status/errorCode ne 0 or riskLevelAggregated ne 'none')"
        $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
        $nextLink = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$encodedFilter&`$top=1000"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($signIn in $response.value) {
                    $errorCode = $signIn.status.errorCode ?? 0
                    $failureReason = $signIn.status.failureReason ?? ""

                    if ($errorCode -ne 0) {
                        $failedCount++
                        if ($failureReason -match 'MFA|multi-factor|50076|50074|50079') {
                            $mfaFailedCount++
                        }
                    }

                    $riskLevel = $signIn.riskLevelAggregated ?? 'none'
                    if ($riskLevel -ne 'none') {
                        $riskyCount++
                    }

                    if ($signIn.isInteractive -eq $true) {
                        $interactiveCount++
                    } else {
                        $nonInteractiveCount++
                    }

                    $createdDT = $signIn.createdDateTime ?? ""
                    $eventDate = if ($createdDT) { ([datetime]$createdDT).ToString("yyyy-MM-dd") } else { $now.ToString("yyyy-MM-dd") }

                    $signInObj = @{
                        id = $signIn.id ?? ""
                        eventType = "signIn"
                        eventDate = $eventDate
                        createdDateTime = $createdDT
                        userDisplayName = $signIn.userDisplayName ?? ""
                        userPrincipalName = $signIn.userPrincipalName ?? ""
                        userId = $signIn.userId ?? ""
                        appId = $signIn.appId ?? ""
                        appDisplayName = $signIn.appDisplayName ?? ""
                        ipAddress = $signIn.ipAddress ?? ""
                        clientAppUsed = $signIn.clientAppUsed ?? ""
                        isInteractive = if ($null -ne $signIn.isInteractive) { $signIn.isInteractive } else { $null }
                        errorCode = $errorCode
                        failureReason = $failureReason
                        additionalDetails = $signIn.status.additionalDetails ?? ""
                        riskLevelAggregated = $riskLevel
                        riskLevelDuringSignIn = $signIn.riskLevelDuringSignIn ?? 'none'
                        riskState = $signIn.riskState ?? ""
                        riskDetail = $signIn.riskDetail ?? ""
                        conditionalAccessStatus = $signIn.conditionalAccessStatus ?? ""
                        appliedConditionalAccessPolicies = $signIn.appliedConditionalAccessPolicies ?? @()
                        location = @{
                            city = $signIn.location.city ?? ""
                            state = $signIn.location.state ?? ""
                            countryOrRegion = $signIn.location.countryOrRegion ?? ""
                        }
                        deviceDetail = @{
                            deviceId = $signIn.deviceDetail.deviceId ?? ""
                            displayName = $signIn.deviceDetail.displayName ?? ""
                            operatingSystem = $signIn.deviceDetail.operatingSystem ?? ""
                            browser = $signIn.deviceDetail.browser ?? ""
                            isCompliant = $signIn.deviceDetail.isCompliant ?? $null
                            isManaged = $signIn.deviceDetail.isManaged ?? $null
                            trustType = $signIn.deviceDetail.trustType ?? ""
                        }
                        resourceDisplayName = $signIn.resourceDisplayName ?? ""
                        resourceId = $signIn.resourceId ?? ""
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$eventsJsonL.AppendLine(($signInObj | ConvertTo-Json -Compress -Depth 10))
                    $signInCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "Sign-in logs batch error: $_"
                break
            }
        }

        $results.SignIns = @{
            Success = $true
            Count = $signInCount
            FailedCount = $failedCount
            RiskyCount = $riskyCount
            MfaFailedCount = $mfaFailedCount
            InteractiveCount = $interactiveCount
            NonInteractiveCount = $nonInteractiveCount
        }
        Write-Verbose "Sign-in logs complete: $signInCount events ($failedCount failed, $riskyCount risky)"
    }
    catch {
        Write-Warning "Sign-in logs collection failed: $_"
        $results.SignIns.Error = $_.Exception.Message
    }

    # Periodic flush
    if ($eventsJsonL.Length -ge $writeThreshold) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $eventsBlobName `
                           -Content $eventsJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Flushed $($eventsJsonL.Length) characters after sign-in logs"
            $eventsJsonL.Clear()
        }
        catch {
            Write-Error "Blob flush failed: $_"
        }
    }
    #endregion

    #region 2. Collect Directory Audits
    Write-Verbose "=== Phase 2: Collecting directory audits ==="

    $auditCount = 0
    $roleManagementCount = 0
    $userManagementCount = 0
    $groupManagementCount = 0
    $applicationManagementCount = 0
    $otherCount = 0

    try {
        $filter = "activityDateTime ge $sinceFormatted"
        $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
        $nextLink = "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=$encodedFilter&`$top=1000"

        while ($nextLink) {
            try {
                $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
                foreach ($audit in $response.value) {
                    $category = $audit.category ?? 'Other'
                    switch ($category) {
                        'RoleManagement' { $roleManagementCount++ }
                        'UserManagement' { $userManagementCount++ }
                        'GroupManagement' { $groupManagementCount++ }
                        'ApplicationManagement' { $applicationManagementCount++ }
                        default { $otherCount++ }
                    }

                    $initiatedBy = @{
                        user = @{
                            id = $audit.initiatedBy.user.id ?? ""
                            displayName = $audit.initiatedBy.user.displayName ?? ""
                            userPrincipalName = $audit.initiatedBy.user.userPrincipalName ?? ""
                        }
                        app = @{
                            appId = $audit.initiatedBy.app.appId ?? ""
                            displayName = $audit.initiatedBy.app.displayName ?? ""
                            servicePrincipalId = $audit.initiatedBy.app.servicePrincipalId ?? ""
                        }
                    }

                    $targetResources = @()
                    if ($audit.targetResources) {
                        foreach ($target in $audit.targetResources) {
                            $targetResources += @{
                                id = $target.id ?? ""
                                displayName = $target.displayName ?? ""
                                type = $target.type ?? ""
                                userPrincipalName = $target.userPrincipalName ?? ""
                                modifiedProperties = $target.modifiedProperties ?? @()
                            }
                        }
                    }

                    $activityDT = $audit.activityDateTime ?? ""
                    $eventDate = if ($activityDT) { ([datetime]$activityDT).ToString("yyyy-MM-dd") } else { $now.ToString("yyyy-MM-dd") }

                    $auditObj = @{
                        id = $audit.id ?? ""
                        eventType = "audit"
                        eventDate = $eventDate
                        activityDateTime = $activityDT
                        activityDisplayName = $audit.activityDisplayName ?? ""
                        category = $category
                        correlationId = $audit.correlationId ?? ""
                        result = $audit.result ?? ""
                        resultReason = $audit.resultReason ?? ""
                        loggedByService = $audit.loggedByService ?? ""
                        operationType = $audit.operationType ?? ""
                        initiatedBy = $initiatedBy
                        targetResources = $targetResources
                        additionalDetails = $audit.additionalDetails ?? @()
                        collectionTimestamp = $timestampFormatted
                    }

                    [void]$eventsJsonL.AppendLine(($auditObj | ConvertTo-Json -Compress -Depth 10))
                    $auditCount++
                }
                $nextLink = $response.'@odata.nextLink'
            }
            catch {
                Write-Warning "Directory audits batch error: $_"
                break
            }
        }

        $results.Audits = @{
            Success = $true
            Count = $auditCount
            RoleManagementCount = $roleManagementCount
            UserManagementCount = $userManagementCount
            GroupManagementCount = $groupManagementCount
            ApplicationManagementCount = $applicationManagementCount
            OtherCount = $otherCount
        }
        Write-Verbose "Directory audits complete: $auditCount events"
    }
    catch {
        Write-Warning "Directory audits collection failed: $_"
        $results.Audits.Error = $_.Exception.Message
    }
    #endregion

    #region Final Flush
    if ($eventsJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $eventsBlobName `
                           -Content $eventsJsonL.ToString() `
                           -AccessToken $storageToken
            Write-Verbose "Final flush: $($eventsJsonL.Length) characters written"
        }
        catch {
            Write-Error "Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }
    #endregion

    # Cleanup
    $eventsJsonL.Clear()
    $eventsJsonL = $null

    # Garbage collection
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    # Determine overall success
    $overallSuccess = $results.SignIns.Success -or $results.Audits.Success
    $totalCount = $results.SignIns.Count + $results.Audits.Count

    Write-Verbose "Combined events collection complete: $totalCount total events"

    return @{
        Success = $overallSuccess
        Timestamp = $timestamp
        BlobName = $eventsBlobName
        EventCount = $totalCount
        LastCollectionTimestamp = $timestampFormatted

        # Detailed counts
        SignInCount = $results.SignIns.Count
        AuditCount = $results.Audits.Count

        # Detailed results
        Results = $results

        Summary = @{
            timestamp = $timestampFormatted
            sinceDateTime = $sinceFormatted
            totalCount = $totalCount
            signIns = @{
                total = $results.SignIns.Count
                failed = $results.SignIns.FailedCount
                risky = $results.SignIns.RiskyCount
                mfaFailed = $results.SignIns.MfaFailedCount
                interactive = $results.SignIns.InteractiveCount
                nonInteractive = $results.SignIns.NonInteractiveCount
            }
            audits = @{
                total = $results.Audits.Count
                roleManagement = $results.Audits.RoleManagementCount
                userManagement = $results.Audits.UserManagementCount
                groupManagement = $results.Audits.GroupManagementCount
                applicationManagement = $results.Audits.ApplicationManagementCount
                other = $results.Audits.OtherCount
            }
        }
    }
}
catch {
    Write-Error "Combined events collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
