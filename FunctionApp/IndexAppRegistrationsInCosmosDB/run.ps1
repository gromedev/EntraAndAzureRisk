#region Index App Registrations in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes App Registrations in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides app registration-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $appRegistrationsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # App registration-specific configuration
    $config = @{
        EntityType = 'appRegistrations'
        EntityNameSingular = 'appRegistration'
        EntityNamePlural = 'AppRegistrations'
        CompareFields = @(
            'displayName',
            'signInAudience',
            'publisherDomain',
            'passwordCredentials',
            'keyCredentials',
            'secretCount',
            'certificateCount'
        )
        ArrayFields = @('passwordCredentials', 'keyCredentials')  # Credentials arrays compared as JSON
        DocumentFields = @{
            appId = 'appId'
            displayName = 'displayName'
            createdDateTime = 'createdDateTime'
            signInAudience = 'signInAudience'
            publisherDomain = 'publisherDomain'
            passwordCredentials = 'passwordCredentials'
            keyCredentials = 'keyCredentials'
            secretCount = 'secretCount'
            certificateCount = 'certificateCount'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $appRegistrationsRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name appRegistrationsRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) app registrations to app_registrations_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name appRegistrationChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to app_registration_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalAppRegistrations = $result.Statistics.Total
        NewAppRegistrations = $result.Statistics.New
        ModifiedAppRegistrations = $result.Statistics.Modified
        DeletedAppRegistrations = $result.Statistics.Deleted
        UnchangedAppRegistrations = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalAppRegistrations = 0
        NewAppRegistrations = 0
        ModifiedAppRegistrations = 0
        DeletedAppRegistrations = 0
        UnchangedAppRegistrations = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
