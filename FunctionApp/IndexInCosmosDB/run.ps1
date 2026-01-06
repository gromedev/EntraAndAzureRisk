#region Index Users in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes users in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides user-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $usersRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # User-specific configuration
    $config = @{
        EntityType = 'users'
        EntityNameSingular = 'user'
        EntityNamePlural = 'Users'
        CompareFields = @(
            'accountEnabled',
            'userType',
            'lastSignInDateTime',
            'userPrincipalName',
            'displayName',
            'passwordPolicies',
            'usageLocation',
            'externalUserState',
            'externalUserStateChangeDateTime',
            'onPremisesSyncEnabled',
            'onPremisesSamAccountName',
            'onPremisesUserPrincipalName',
            'onPremisesSecurityIdentifier',
            'deleted'
        )
        ArrayFields = @()  # Users have no array fields to compare
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            accountEnabled = 'accountEnabled'
            userType = 'userType'
            createdDateTime = 'createdDateTime'
            lastSignInDateTime = 'lastSignInDateTime'
            displayName = 'displayName'
            passwordPolicies = 'passwordPolicies'
            usageLocation = 'usageLocation'
            externalUserState = 'externalUserState'
            externalUserStateChangeDateTime = 'externalUserStateChangeDateTime'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSamAccountName = 'onPremisesSamAccountName'
            onPremisesUserPrincipalName = 'onPremisesUserPrincipalName'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $usersRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name usersRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) users to users_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name userChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to user_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalUsers = $result.Statistics.Total
        NewUsers = $result.Statistics.New
        ModifiedUsers = $result.Statistics.Modified
        DeletedUsers = $result.Statistics.Deleted
        UnchangedUsers = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalUsers = 0
        NewUsers = 0
        ModifiedUsers = 0
        DeletedUsers = 0
        UnchangedUsers = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
