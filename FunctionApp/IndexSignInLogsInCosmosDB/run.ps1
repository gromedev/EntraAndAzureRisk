#region Index Sign-In Logs in Cosmos DB - Append Only
<#
.SYNOPSIS
    Indexes Sign-In Logs in Cosmos DB (append-only, no delta detection)
.DESCRIPTION
    Event-based data - each sign-in log is a unique event.
    No delta detection is performed; all events are written directly.
    Uses Azure Functions bindings for Cosmos DB output.
#>
#endregion

param($ActivityInput)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    Write-Verbose "Starting Sign-In Logs indexing (append-only)"

    # Get tokens for blob access
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Read sign-in logs from blob
    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$($ActivityInput.BlobName)"

    Write-Verbose "Reading sign-in logs from blob: $($ActivityInput.BlobName)"

    try {
        $headers = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version' = '2020-04-08'
        }
        $blobResponse = Invoke-RestMethod -Uri $blobUri -Headers $headers -Method Get
        $signInLines = $blobResponse -split "`n" | Where-Object { $_.Trim() -ne "" }
        Write-Verbose "Found $($signInLines.Count) sign-in logs in blob"
    }
    catch {
        Write-Error "Failed to read blob: $_"
        return @{
            Success = $false
            Error = "Failed to read blob: $($_.Exception.Message)"
        }
    }

    # Process sign-in logs
    $signInDocuments = [System.Collections.ArrayList]::new()
    $signInCount = 0

    foreach ($line in $signInLines) {
        try {
            $signIn = $line | ConvertFrom-Json

            # Create Cosmos document with id as the sign-in id
            $doc = @{
                id = $signIn.id
                createdDateTime = $signIn.createdDateTime
                userDisplayName = $signIn.userDisplayName
                userPrincipalName = $signIn.userPrincipalName
                userId = $signIn.userId
                appId = $signIn.appId
                appDisplayName = $signIn.appDisplayName
                ipAddress = $signIn.ipAddress
                clientAppUsed = $signIn.clientAppUsed
                isInteractive = $signIn.isInteractive
                errorCode = $signIn.errorCode
                failureReason = $signIn.failureReason
                additionalDetails = $signIn.additionalDetails
                riskLevelAggregated = $signIn.riskLevelAggregated
                riskLevelDuringSignIn = $signIn.riskLevelDuringSignIn
                riskState = $signIn.riskState
                riskDetail = $signIn.riskDetail
                conditionalAccessStatus = $signIn.conditionalAccessStatus
                appliedConditionalAccessPolicies = $signIn.appliedConditionalAccessPolicies
                location = $signIn.location
                deviceDetail = $signIn.deviceDetail
                resourceDisplayName = $signIn.resourceDisplayName
                resourceId = $signIn.resourceId
                collectionTimestamp = $signIn.collectionTimestamp
                snapshotId = $ActivityInput.Timestamp
                # TTL for 90 days (7776000 seconds) - optional, can be removed if you want to keep forever
                ttl = 7776000
            }

            [void]$signInDocuments.Add($doc)
            $signInCount++
        }
        catch {
            Write-Warning "Failed to process sign-in log: $_"
        }
    }

    # Push to output binding
    if ($signInDocuments.Count -gt 0) {
        Push-OutputBinding -Name signInLogsOut -Value $signInDocuments.ToArray()
        Write-Verbose "Queued $($signInDocuments.Count) sign-in logs to signin_logs container"
    }

    # Create snapshot document
    $snapshotDoc = @{
        id = "$($ActivityInput.Timestamp)-signInLogs"
        snapshotId = $ActivityInput.Timestamp
        collectionTimestamp = $ActivityInput.Summary.collectionTimestamp ?? (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'signInLogs'
        blobPath = $ActivityInput.BlobName
        totalSignInLogs = $signInCount
        sinceDateTime = $ActivityInput.Summary.sinceDateTime ?? ""
        failedCount = $ActivityInput.Summary.failedCount ?? 0
        riskyCount = $ActivityInput.Summary.riskyCount ?? 0
        mfaFailedCount = $ActivityInput.Summary.mfaFailedCount ?? 0
    }

    Push-OutputBinding -Name snapshotsOut -Value $snapshotDoc
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalSignInLogs = $signInCount
        CosmosWriteCount = $signInCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalSignInLogs = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
