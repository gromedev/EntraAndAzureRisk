#region Index Azure RBAC in Cosmos DB - Simplified Wrapper
<#
.SYNOPSIS
    Indexes Azure RBAC assignments in Cosmos DB with delta change detection
.DESCRIPTION
    Uses Invoke-DeltaIndexingWithBindings with config from IndexerConfigs.psd1.
    Configuration and binding logic handled by the shared function.
#>
#endregion

param($ActivityInput, $azureRbacRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBindings `
    -EntityType 'azureRbac' `
    -ActivityInput $ActivityInput `
    -ExistingData $azureRbacRawIn
