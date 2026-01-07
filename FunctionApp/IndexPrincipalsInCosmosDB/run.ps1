#region Index Principals in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes principals (users, groups, SPs, apps, devices) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBindings with config from IndexerConfigs.psd1.
    All principal types are stored in a single container with principalType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $principalsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBindings `
    -EntityType 'principals' `
    -ActivityInput $ActivityInput `
    -ExistingData $principalsRawIn
