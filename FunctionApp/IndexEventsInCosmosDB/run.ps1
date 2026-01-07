#region Index Events in Cosmos DB - Unified Container (Append-Only)
<#
.SYNOPSIS
    Indexes events (Sign-in logs + Directory audits) in unified Cosmos DB container
.DESCRIPTION
    Events are APPEND-ONLY - no delta detection needed.
    All event types are stored in a single container with eventType discriminator.
    Partition key is /eventDate for efficient time-range queries.

    This indexer simply reads from blob and writes all events to Cosmos.
    Deduplication is handled by unique event IDs (Graph API provides these).
#>
#endregion

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

#region Validate Input
if (-not $ActivityInput) {
    return @{
        Success = $false
        Error = "ActivityInput is required"
    }
}

$blobName = $ActivityInput.BlobName
$timestamp = $ActivityInput.Timestamp

if (-not $blobName) {
    return @{
        Success = $false
        Error = "BlobName is required in ActivityInput"
    }
}
#endregion

try {
    Write-Verbose "Starting events indexing from blob: $blobName"

    # Get storage configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Get storage token
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    # Read events from blob
    Write-Verbose "Reading events from blob storage..."
    $blobContent = Get-BlobContent -StorageAccountName $storageAccountName `
                                   -ContainerName $containerName `
                                   -BlobName $blobName `
                                   -AccessToken $storageToken

    if (-not $blobContent) {
        Write-Warning "Blob content is empty or not found: $blobName"
        return @{
            Success = $true
            TotalEvents = 0
            SignInCount = 0
            AuditCount = 0
            CosmosWriteCount = 0
        }
    }

    # Parse JSONL content
    $events = @()
    $lines = $blobContent -split "`n" | Where-Object { $_.Trim() }
    foreach ($line in $lines) {
        try {
            $event = $line | ConvertFrom-Json
            $events += $event
        }
        catch {
            Write-Warning "Failed to parse line: $($_.Exception.Message)"
        }
    }

    Write-Verbose "Parsed $($events.Count) events from blob"

    if ($events.Count -eq 0) {
        return @{
            Success = $true
            TotalEvents = 0
            SignInCount = 0
            AuditCount = 0
            CosmosWriteCount = 0
        }
    }

    # Count by event type
    $signInCount = ($events | Where-Object { $_.eventType -eq 'signIn' }).Count
    $auditCount = ($events | Where-Object { $_.eventType -eq 'audit' }).Count

    # Prepare documents for Cosmos output binding
    # Each event already has id, eventType, eventDate from collector
    $cosmosDocuments = @()
    foreach ($event in $events) {
        # Ensure required fields
        if (-not $event.id) {
            $event.id = [guid]::NewGuid().ToString()
        }
        if (-not $event.eventDate) {
            # Extract date from createdDateTime for partition key
            $created = $event.createdDateTime ?? $event.activityDateTime
            if ($created) {
                $event.eventDate = ([datetime]$created).ToString("yyyy-MM-dd")
            }
            else {
                $event.eventDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
            }
        }
        $cosmosDocuments += $event
    }

    # Push to output binding
    Push-OutputBinding -Name eventsRawOut -Value $cosmosDocuments

    Write-Verbose "Events indexing complete: $($events.Count) total, $signInCount sign-ins, $auditCount audits"

    return @{
        Success = $true
        TotalEvents = $events.Count
        SignInCount = $signInCount
        AuditCount = $auditCount
        CosmosWriteCount = $events.Count
    }
}
catch {
    Write-Error "Events indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
