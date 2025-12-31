# Auth with Managed Identity
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    $context = (Connect-AzAccount -Identity).Context
    Set-AzContext -Subscription $context.Subscription -DefaultProfile $context | Out-Null
}

# Load Module
$modulesPath = Join-Path $PSScriptRoot 'Modules'
if (Test-Path $modulesPath) {
    $env:PSModulePath = "$modulesPath;$env:PSModulePath"
    Import-Module EntraDataCollection -Force -ErrorAction Stop
} else {
    throw "Modules folder not found at $modulesPath"
}