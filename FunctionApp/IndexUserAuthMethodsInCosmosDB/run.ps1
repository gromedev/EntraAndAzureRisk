#region Index User Auth Methods in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes User Authentication Methods in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides auth methods-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $userAuthMethodsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # User auth methods-specific configuration
    $config = @{
        EntityType = 'userAuthMethods'
        EntityNameSingular = 'userAuthMethod'
        EntityNamePlural = 'UserAuthMethods'
        CompareFields = @(
            'perUserMfaState',
            'hasAuthenticator',
            'hasPhone',
            'hasFido2',
            'hasEmail',
            'hasPassword',
            'hasTap',
            'hasWindowsHello',
            'methodCount',
            'methods'
        )
        ArrayFields = @('methods')  # Methods array compared as JSON
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            displayName = 'displayName'
            accountEnabled = 'accountEnabled'
            perUserMfaState = 'perUserMfaState'
            hasAuthenticator = 'hasAuthenticator'
            hasPhone = 'hasPhone'
            hasFido2 = 'hasFido2'
            hasEmail = 'hasEmail'
            hasPassword = 'hasPassword'
            hasTap = 'hasTap'
            hasWindowsHello = 'hasWindowsHello'
            methodCount = 'methodCount'
            methods = 'methods'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $false  # Don't write deletes for auth methods (linked to users)
        IncludeDeleteMarkers = $false
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $userAuthMethodsRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name userAuthMethodsRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) user auth methods to user_auth_methods_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name userAuthMethodChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to user_auth_method_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalUserAuthMethods = $result.Statistics.Total
        NewUserAuthMethods = $result.Statistics.New
        ModifiedUserAuthMethods = $result.Statistics.Modified
        DeletedUserAuthMethods = $result.Statistics.Deleted
        UnchangedUserAuthMethods = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalUserAuthMethods = 0
        NewUserAuthMethods = 0
        ModifiedUserAuthMethods = 0
        DeletedUserAuthMethods = 0
        UnchangedUserAuthMethods = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
