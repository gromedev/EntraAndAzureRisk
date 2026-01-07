#region Index Relationships in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes relationships (memberships, roles, permissions) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBindings with config from IndexerConfigs.psd1.
    All relationship types are stored in a single container with relationType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $relationshipsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBindings `
    -EntityType 'relationships' `
    -ActivityInput $ActivityInput `
    -ExistingData $relationshipsRawIn
