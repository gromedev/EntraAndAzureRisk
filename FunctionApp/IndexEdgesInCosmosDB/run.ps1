#region Index Edges in Cosmos DB - Unified Container (V3)
<#
.SYNOPSIS
    Indexes edges (all relationships) in unified Cosmos DB container
.DESCRIPTION
    V3 Architecture: Unified edges container
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All edge types (Entra + Azure relationships) are stored in a single container with edgeType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $edgesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# DEBUG: Log the input binding data count
$existingCount = if ($edgesRawIn) { @($edgesRawIn).Count } else { 0 }
Write-Host "DEBUG-DELTA: edgesRawIn contains $existingCount existing edge documents from Cosmos DB input binding"
if ($existingCount -eq 0) {
    Write-Warning "DEBUG-DELTA: No existing edge data from input binding - all edges will appear as NEW"
}

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'edges' `
    -ActivityInput $ActivityInput `
    -ExistingData $edgesRawIn
