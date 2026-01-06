#region Index Directory Audits in Cosmos DB - Append Only
<#
.SYNOPSIS
    Indexes Directory Audit Logs in Cosmos DB (append-only, no delta detection)
.DESCRIPTION
    Event-based data - each audit log is a unique event.
    No delta detection is performed; all events are written directly.
    Uses Azure Functions bindings for Cosmos DB output.
#>
#endregion

param($ActivityInput)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    Write-Verbose "Starting Directory Audit Logs indexing (append-only)"

    # Get tokens for blob access
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Read audit logs from blob
    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$($ActivityInput.BlobName)"

    Write-Verbose "Reading directory audits from blob: $($ActivityInput.BlobName)"

    try {
        $headers = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version' = '2020-04-08'
        }
        $blobResponse = Invoke-RestMethod -Uri $blobUri -Headers $headers -Method Get
        $auditLines = $blobResponse -split "`n" | Where-Object { $_.Trim() -ne "" }
        Write-Verbose "Found $($auditLines.Count) directory audits in blob"
    }
    catch {
        Write-Error "Failed to read blob: $_"
        return @{
            Success = $false
            Error = "Failed to read blob: $($_.Exception.Message)"
        }
    }

    # Process audit logs
    $auditDocuments = [System.Collections.ArrayList]::new()
    $auditCount = 0

    foreach ($line in $auditLines) {
        try {
            $audit = $line | ConvertFrom-Json

            # Create Cosmos document with id as the audit id
            $doc = @{
                id = $audit.id
                activityDateTime = $audit.activityDateTime
                activityDisplayName = $audit.activityDisplayName
                category = $audit.category
                correlationId = $audit.correlationId
                result = $audit.result
                resultReason = $audit.resultReason
                loggedByService = $audit.loggedByService
                operationType = $audit.operationType
                initiatedBy = $audit.initiatedBy
                targetResources = $audit.targetResources
                additionalDetails = $audit.additionalDetails
                collectionTimestamp = $audit.collectionTimestamp
                snapshotId = $ActivityInput.Timestamp
                # TTL for 90 days (7776000 seconds) - optional
                ttl = 7776000
            }

            [void]$auditDocuments.Add($doc)
            $auditCount++
        }
        catch {
            Write-Warning "Failed to process audit log: $_"
        }
    }

    # Push to output binding
    if ($auditDocuments.Count -gt 0) {
        Push-OutputBinding -Name directoryAuditsOut -Value $auditDocuments.ToArray()
        Write-Verbose "Queued $($auditDocuments.Count) directory audits to directory_audits container"
    }

    # Create snapshot document
    $snapshotDoc = @{
        id = "$($ActivityInput.Timestamp)-directoryAudits"
        snapshotId = $ActivityInput.Timestamp
        collectionTimestamp = $ActivityInput.Summary.collectionTimestamp ?? (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'directoryAudits'
        blobPath = $ActivityInput.BlobName
        totalDirectoryAudits = $auditCount
        sinceDateTime = $ActivityInput.Summary.sinceDateTime ?? ""
        roleManagementCount = $ActivityInput.Summary.roleManagementCount ?? 0
        userManagementCount = $ActivityInput.Summary.userManagementCount ?? 0
        groupManagementCount = $ActivityInput.Summary.groupManagementCount ?? 0
        applicationManagementCount = $ActivityInput.Summary.applicationManagementCount ?? 0
    }

    Push-OutputBinding -Name snapshotsOut -Value $snapshotDoc
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalDirectoryAudits = $auditCount
        CosmosWriteCount = $auditCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalDirectoryAudits = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
