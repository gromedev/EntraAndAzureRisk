#region Index Policies in Cosmos DB - Unified Container
<#
.SYNOPSIS
    Indexes policies (CA + Role policies) in unified Cosmos DB container
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBinding with config from IndexerConfigs.psd1.
    All policy types are stored in a single container with policyType discriminator.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $policiesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'policies' `
    -ActivityInput $ActivityInput `
    -ExistingData $policiesRawIn
