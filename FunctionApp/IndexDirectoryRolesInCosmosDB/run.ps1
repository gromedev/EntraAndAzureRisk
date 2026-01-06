#region Index Directory Roles in Cosmos DB - Thin Wrapper
<#
.SYNOPSIS
    Indexes Directory Roles in Cosmos DB with delta change detection
.DESCRIPTION
    Thin wrapper around Invoke-DeltaIndexing that provides directory role-specific configuration.
    Uses Azure Functions bindings for Cosmos DB input/output.
#>
#endregion

param($ActivityInput, $directoryRolesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    # Directory role-specific configuration
    $config = @{
        EntityType = 'directoryRoles'
        EntityNameSingular = 'directoryRole'
        EntityNamePlural = 'DirectoryRoles'
        CompareFields = @(
            'displayName',
            'description',
            'roleTemplateId',
            'isPrivileged',
            'memberCount',
            'members',
            'deleted'
        )
        ArrayFields = @('members')  # Members array compared as JSON
        DocumentFields = @{
            displayName = 'displayName'
            description = 'description'
            roleTemplateId = 'roleTemplateId'
            isPrivileged = 'isPrivileged'
            memberCount = 'memberCount'
            members = 'members'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
    }

    # Call shared delta indexing logic
    $result = Invoke-DeltaIndexing `
        -BlobName $ActivityInput.BlobName `
        -Timestamp $ActivityInput.Timestamp `
        -ExistingData $directoryRolesRawIn `
        -Config $config

    # Push to output bindings
    if ($result.RawDocuments.Count -gt 0) {
        Push-OutputBinding -Name directoryRolesRawOut -Value $result.RawDocuments
        Write-Verbose "Queued $($result.RawDocuments.Count) directory roles to directory_roles_raw container"
    }

    if ($result.ChangeDocuments.Count -gt 0) {
        Push-OutputBinding -Name directoryRoleChangesOut -Value $result.ChangeDocuments
        Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to directory_role_changes container"
    }

    Push-OutputBinding -Name snapshotsOut -Value $result.SnapshotDocument
    Write-Verbose "Queued snapshot summary to snapshots container"

    # Return statistics
    return @{
        Success = $true
        TotalDirectoryRoles = $result.Statistics.Total
        NewDirectoryRoles = $result.Statistics.New
        ModifiedDirectoryRoles = $result.Statistics.Modified
        DeletedDirectoryRoles = $result.Statistics.Deleted
        UnchangedDirectoryRoles = $result.Statistics.Unchanged
        CosmosWriteCount = $result.Statistics.WriteCount
        SnapshotId = $ActivityInput.Timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalDirectoryRoles = 0
        NewDirectoryRoles = 0
        ModifiedDirectoryRoles = 0
        DeletedDirectoryRoles = 0
        UnchangedDirectoryRoles = 0
        CosmosWriteCount = 0
        SnapshotId = $ActivityInput.Timestamp
    }
}
