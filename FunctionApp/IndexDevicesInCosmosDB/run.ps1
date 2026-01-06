#region Index Devices in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes devices in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides device-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $devicesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # Device-specific configuration
    $config = @{
        EntityType = 'devices'
        EntityNameSingular = 'device'
        EntityNamePlural = 'Devices'
        CompareFields = @(
            'displayName',
            'accountEnabled',
            'operatingSystem',
            'operatingSystemVersion',
            'isCompliant',
            'isManaged',
            'trustType',
            'approximateLastSignInDateTime',
            'manufacturer',
            'model',
            'profileType'
        )
        ArrayFields = @()  # Devices have no array fields to compare
        DocumentFields = @{
            displayName = 'displayName'
            deviceId = 'deviceId'
            accountEnabled = 'accountEnabled'
            operatingSystem = 'operatingSystem'
            operatingSystemVersion = 'operatingSystemVersion'
            isCompliant = 'isCompliant'
            isManaged = 'isManaged'
            trustType = 'trustType'
            approximateLastSignInDateTime = 'approximateLastSignInDateTime'
            createdDateTime = 'createdDateTime'
            deviceVersion = 'deviceVersion'
            manufacturer = 'manufacturer'
            model = 'model'
            profileType = 'profileType'
            registrationDateTime = 'registrationDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $devicesRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name devicesRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) devices to devices_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name deviceChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to device_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalDevices = $result.Statistics.Total
        NewDevices = $result.Statistics.New
        ModifiedDevices = $result.Statistics.Modified
        DeletedDevices = $result.Statistics.Deleted
        UnchangedDevices = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalDevices = 0
        NewDevices = 0
        ModifiedDevices = 0
        DeletedDevices = 0
        UnchangedDevices = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
