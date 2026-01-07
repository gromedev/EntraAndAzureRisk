param($ActivityInput, $eventsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Use shared function with entity type - all config loaded from IndexerConfigs.psd1
return Invoke-DeltaIndexingWithBinding `
    -EntityType 'events' `
    -ActivityInput $ActivityInput `
    -ExistingData $eventsRawIn
