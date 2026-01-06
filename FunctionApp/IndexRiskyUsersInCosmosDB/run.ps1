#region Index Risky Users in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes risky users in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides risky user-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $riskyUsersRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # Risky user-specific configuration
    $config = @{
        EntityType = 'riskyUsers'
        EntityNameSingular = 'riskyUser'
        EntityNamePlural = 'RiskyUsers'
        CompareFields = @(
            'userPrincipalName',
            'userDisplayName',
            'riskLevel',
            'riskState',
            'riskDetail',
            'riskLastUpdatedDateTime',
            'isDeleted',
            'isProcessing',
            'deleted'
        )
        ArrayFields = @()  # Risky users have no array fields to compare
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            userDisplayName = 'userDisplayName'
            riskLevel = 'riskLevel'
            riskState = 'riskState'
            riskDetail = 'riskDetail'
            riskLastUpdatedDateTime = 'riskLastUpdatedDateTime'
            isDeleted = 'isDeleted'
            isProcessing = 'isProcessing'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $riskyUsersRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name riskyUsersRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) risky users to risky_users_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name riskyUserChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to risky_user_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalRiskyUsers = $result.Statistics.Total
        NewRiskyUsers = $result.Statistics.New
        ModifiedRiskyUsers = $result.Statistics.Modified
        DeletedRiskyUsers = $result.Statistics.Deleted
        UnchangedRiskyUsers = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalRiskyUsers = 0
        NewRiskyUsers = 0
        ModifiedRiskyUsers = 0
        DeletedRiskyUsers = 0
        UnchangedRiskyUsers = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
