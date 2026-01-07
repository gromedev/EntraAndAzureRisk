#region Index Azure Resources in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes Azure resources (hierarchy, key vaults, VMs) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All Azure resource types are stored in a single container with resourceType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $azureResourcesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'azureResources' `
    -ActivityInput $ActivityInput `
    -ExistingData $azureResourcesRawIn
