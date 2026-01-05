#region Index Groups in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes groups in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides group-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $groupsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # Group-specific configuration
    $config = @{
        EntityType = 'groups'
        EntityNameSingular = 'group'
        EntityNamePlural = 'Groups'
        CompareFields = @(
            'displayName',
            'classification',
            'description',
            'groupTypes',
            'mailEnabled',
            'membershipRule',
            'securityEnabled',
            'isAssignableToRole',
            'visibility',
            'onPremisesSyncEnabled',
            'mail'
        )
        ArrayFields = @('groupTypes')  # groupTypes is an array field
        DocumentFields = @{
            displayName = 'displayName'
            classification = 'classification'
            deletedDateTime = 'deletedDateTime'
            description = 'description'
            groupTypes = 'groupTypes'
            mailEnabled = 'mailEnabled'
            membershipRule = 'membershipRule'
            securityEnabled = 'securityEnabled'
            isAssignableToRole = 'isAssignableToRole'
            createdDateTime = 'createdDateTime'
            visibility = 'visibility'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            mail = 'mail'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $groupsRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name groupsRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) groups to groups_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name groupChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to group_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalGroups = $result.Statistics.Total
        NewGroups = $result.Statistics.New
        ModifiedGroups = $result.Statistics.Modified
        DeletedGroups = $result.Statistics.Deleted
        UnchangedGroups = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalGroups = 0
        NewGroups = 0
        ModifiedGroups = 0
        DeletedGroups = 0
        UnchangedGroups = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
