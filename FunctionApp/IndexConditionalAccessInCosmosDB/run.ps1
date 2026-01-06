#region Index Conditional Access Policies in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes Conditional Access policies in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides CA policy-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $caPoliciesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # CA policy-specific configuration
    $config = @{
        EntityType = 'conditionalAccessPolicies'
        EntityNameSingular = 'policy'
        EntityNamePlural = 'Policies'
        CompareFields = @(
            'displayName',
            'state',
            'conditions',
            'grantControls',
            'sessionControls'
        )
        ArrayFields = @('conditions', 'grantControls', 'sessionControls')  # Complex objects compared as JSON
        DocumentFields = @{
            displayName = 'displayName'
            state = 'state'
            createdDateTime = 'createdDateTime'
            modifiedDateTime = 'modifiedDateTime'
            conditions = 'conditions'
            grantControls = 'grantControls'
            sessionControls = 'sessionControls'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $caPoliciesRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name caPoliciesRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) policies to ca_policies_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name caPolicyChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to ca_policy_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalPolicies = $result.Statistics.Total
        NewPolicies = $result.Statistics.New
        ModifiedPolicies = $result.Statistics.Modified
        DeletedPolicies = $result.Statistics.Deleted
        UnchangedPolicies = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalPolicies = 0
        NewPolicies = 0
        ModifiedPolicies = 0
        DeletedPolicies = 0
        UnchangedPolicies = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
