#region Index Resources in Cosmos DB - Unified Container (V3)
<#
.SYNOPSIS
    Indexes resources (applications + Azure resources) in unified Cosmos DB container
.DESCRIPTION
    V3 Architecture: Unified resources container
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All resource types (applications, Azure hierarchy, VMs, Key Vaults, etc.) are stored
    in a single container with resourceType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $resourcesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'resources' `
    -ActivityInput $ActivityInput `
    -ExistingData $resourcesRawIn
