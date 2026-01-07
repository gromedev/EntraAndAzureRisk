#region Index Azure Relationships in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes Azure relationships (contains, keyVaultAccess, hasManagedIdentity) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All Azure relationship types are stored in a single container with relationType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $azureRelationshipsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'azureRelationships' `
    -ActivityInput $ActivityInput `
    -ExistingData $azureRelationshipsRawIn
