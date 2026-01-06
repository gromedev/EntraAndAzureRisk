#region Index Role Policies in Cosmos DB - Simplified Wrapper
<#
.SYNOPSIS
    Indexes role policies in Cosmos DB with delta change detection
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBindings with config from IndexerConfigs.psd1.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $rolePoliciesRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBindings `
    -EntityType 'rolePolicies' `
    -ActivityInput $ActivityInput `
    -ExistingData $rolePoliciesRawIn
