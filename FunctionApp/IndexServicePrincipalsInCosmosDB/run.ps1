#region Index Service Principals in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes service principals in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides service principal-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $servicePrincipalsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # Service Principal-specific configuration
    $config = @{
        EntityType = 'servicePrincipals'
        EntityNameSingular = 'servicePrincipal'
        EntityNamePlural = 'ServicePrincipals'
        CompareFields = @(
            'accountEnabled',
            'appRoleAssignmentRequired',
            'displayName',
            'appDisplayName',
            'servicePrincipalType',
            'description',
            'notes',
            'deletedDateTime',
            'addIns',
            'oauth2PermissionScopes',
            'resourceSpecificApplicationPermissions',
            'servicePrincipalNames',
            'tags'
        )
        ArrayFields = @(
            'addIns',
            'oauth2PermissionScopes',
            'resourceSpecificApplicationPermissions',
            'servicePrincipalNames',
            'tags'
        )
        DocumentFields = @{
            appId = 'appId'
            displayName = 'displayName'
            appDisplayName = 'appDisplayName'
            servicePrincipalType = 'servicePrincipalType'
            accountEnabled = 'accountEnabled'
            appRoleAssignmentRequired = 'appRoleAssignmentRequired'
            deletedDateTime = 'deletedDateTime'
            description = 'description'
            notes = 'notes'
            addIns = 'addIns'
            oauth2PermissionScopes = 'oauth2PermissionScopes'
            resourceSpecificApplicationPermissions = 'resourceSpecificApplicationPermissions'
            servicePrincipalNames = 'servicePrincipalNames'
            tags = 'tags'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $false  # Service principals don't write deletes to raw container
        IncludeDeleteMarkers = $false  # No soft delete markers for service principals
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $servicePrincipalsRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name servicePrincipalsRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) service principals to service_principals_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name servicePrincipalChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to service_principal_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalServicePrincipals = $result.Statistics.Total
        NewServicePrincipals = $result.Statistics.New
        ModifiedServicePrincipals = $result.Statistics.Modified
        DeletedServicePrincipals = $result.Statistics.Deleted
        UnchangedServicePrincipals = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalServicePrincipals = 0
        NewServicePrincipals = 0
        ModifiedServicePrincipals = 0
        DeletedServicePrincipals = 0
        UnchangedServicePrincipals = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
