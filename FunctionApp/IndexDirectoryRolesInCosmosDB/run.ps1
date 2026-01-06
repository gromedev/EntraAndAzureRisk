#region Index Directory Roles in Cosmos DB - Simplified Wrapper
<#
.SYNOPSIS
    Indexes Directory Roles in Cosmos DB with delta change detection
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBindings with config from IndexerConfigs.psd1.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $directoryRolesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBindings `
    -EntityType 'directoryRoles' `
    -ActivityInput $ActivityInput `
    -ExistingData $directoryRolesRawIn
