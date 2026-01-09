#region Index Principals in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes principals (users, groups, SPs, apps, devices) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All principal types are stored in a single container with principalType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $principalsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# DEBUG: Log the input binding data count
$existingCount = if ($principalsRawIn) { @($principalsRawIn).Count } else { 0 }
Write-Host "DEBUG-DELTA: principalsRawIn contains $existingCount existing documents from Cosmos DB input binding"
if ($existingCount -eq 0) {
    Write-Warning "DEBUG-DELTA: No existing data from input binding - all entities will appear as NEW"
}

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'principals' `
    -ActivityInput $ActivityInput `
    -ExistingData $principalsRawIn
