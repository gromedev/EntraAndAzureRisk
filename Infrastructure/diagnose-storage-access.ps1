#Requires -Modules Az.Accounts, Az.Resources, Az.Storage, Az.Websites

<#
.SYNOPSIS
    Diagnoses storage access issues for the Function App

.PARAMETER ResourceGroupName
    Resource group name

.EXAMPLE
    .\diagnose-storage-access.ps1 -ResourceGroupName "rg-entrarisk-pilot-001"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-entrarisk-pilot-001"
)

function Write-DiagnosticHeader {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-DiagnosticCheck {
    param(
        [string]$Item,
        [bool]$Passed,
        [string]$Details = ""
    )

    $symbol = if ($Passed) { "[✓]" } else { "[✗]" }
    $color = if ($Passed) { "Green" } else { "Red" }

    Write-Host "$symbol $Item" -ForegroundColor $color
    if ($Details) {
        Write-Host "    $Details" -ForegroundColor Gray
    }
}

Write-DiagnosticHeader "Storage Access Diagnostic Tool"

# 1. Check if resource group exists
Write-Host "`n1. Checking Resource Group..." -ForegroundColor Yellow
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg) {
    Write-DiagnosticCheck "Resource Group Exists" $true $rg.ResourceGroupName
} else {
    Write-DiagnosticCheck "Resource Group Exists" $false "Not found: $ResourceGroupName"
    Write-Host "`nAvailable resource groups:" -ForegroundColor Gray
    Get-AzResourceGroup | Select-Object ResourceGroupName | Format-Table
    exit 1
}

# 2. Find the storage account
Write-Host "`n2. Checking Storage Account..." -ForegroundColor Yellow
$storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($storageAccounts.Count -eq 0) {
    Write-DiagnosticCheck "Storage Account Exists" $false "No storage accounts found"
    exit 1
}

$storageAccount = $storageAccounts | Where-Object { $_.StorageAccountName -like "st*" } | Select-Object -First 1
Write-DiagnosticCheck "Storage Account Found" $true $storageAccount.StorageAccountName

# 3. Check if raw-data container exists
Write-Host "`n3. Checking Blob Container..." -ForegroundColor Yellow
$ctx = $storageAccount.Context
$container = Get-AzStorageContainer -Name "raw-data" -Context $ctx -ErrorAction SilentlyContinue
if ($container) {
    Write-DiagnosticCheck "Container 'raw-data' Exists" $true

    # Check if container has any blobs
    $blobs = Get-AzStorageBlob -Container "raw-data" -Context $ctx -ErrorAction SilentlyContinue
    Write-DiagnosticCheck "Blobs in Container" ($blobs.Count -gt 0) "$($blobs.Count) blob(s) found"
} else {
    Write-DiagnosticCheck "Container 'raw-data' Exists" $false "Container not found!"
    Write-Host "`nAvailable containers:" -ForegroundColor Gray
    Get-AzStorageContainer -Context $ctx | Select-Object Name | Format-Table
}

# 4. Find and check Function App
Write-Host "`n4. Checking Function App..." -ForegroundColor Yellow
$functionApps = Get-AzWebApp -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
    Where-Object { $_.Kind -like "*function*" }

if ($functionApps.Count -eq 0) {
    Write-DiagnosticCheck "Function App Exists" $false "No function apps found"
    exit 1
}

$functionApp = $functionApps | Select-Object -First 1
Write-DiagnosticCheck "Function App Found" $true $functionApp.Name

# 5. Check Managed Identity
Write-Host "`n5. Checking Managed Identity..." -ForegroundColor Yellow
$hasManagedIdentity = $functionApp.Identity.Type -eq "SystemAssigned"
Write-DiagnosticCheck "System-Assigned Identity Enabled" $hasManagedIdentity

if ($hasManagedIdentity) {
    $principalId = $functionApp.Identity.PrincipalId
    Write-Host "    Principal ID: $principalId" -ForegroundColor Gray
}

# 6. Check Environment Variables
Write-Host "`n6. Checking Function App Configuration..." -ForegroundColor Yellow
$appSettings = $functionApp.SiteConfig.AppSettings
$storageAccountNameSetting = $appSettings | Where-Object { $_.Name -eq "STORAGE_ACCOUNT_NAME" }

if ($storageAccountNameSetting) {
    $configuredStorageName = $storageAccountNameSetting.Value
    $namesMatch = $configuredStorageName -eq $storageAccount.StorageAccountName
    Write-DiagnosticCheck "STORAGE_ACCOUNT_NAME Setting" $namesMatch
    Write-Host "    Configured: $configuredStorageName" -ForegroundColor Gray
    Write-Host "    Actual:     $($storageAccount.StorageAccountName)" -ForegroundColor Gray

    if (-not $namesMatch) {
        Write-Host "`n⚠️  MISMATCH DETECTED!" -ForegroundColor Red
        Write-Host "The function app is configured to use a different storage account!" -ForegroundColor Red
    }
} else {
    Write-DiagnosticCheck "STORAGE_ACCOUNT_NAME Setting" $false "Environment variable not set!"
}

# 7. Check RBAC Assignments
Write-Host "`n7. Checking RBAC Assignments..." -ForegroundColor Yellow
if ($hasManagedIdentity) {
    $roleAssignments = Get-AzRoleAssignment -ObjectId $principalId -Scope $storageAccount.Id -ErrorAction SilentlyContinue

    $hasBlobReader = $roleAssignments | Where-Object {
        $_.RoleDefinitionName -in @("Storage Blob Data Reader", "Storage Blob Data Contributor", "Storage Blob Data Owner")
    }

    if ($hasBlobReader) {
        Write-DiagnosticCheck "Storage Blob Role Assigned" $true $hasBlobReader.RoleDefinitionName
    } else {
        Write-DiagnosticCheck "Storage Blob Role Assigned" $false "No blob data role found!"

        Write-Host "`nCurrent role assignments:" -ForegroundColor Gray
        $roleAssignments | Select-Object RoleDefinitionName, Scope | Format-Table
    }
} else {
    Write-Host "    Skipped - No managed identity" -ForegroundColor Gray
}

# 8. Summary and Recommendations
Write-DiagnosticHeader "Diagnostic Summary"

Write-Host "`nKey Information:" -ForegroundColor Yellow
Write-Host "  Resource Group:    $ResourceGroupName"
Write-Host "  Storage Account:   $($storageAccount.StorageAccountName)"
Write-Host "  Function App:      $($functionApp.Name)"
Write-Host "  Function App URL:  https://$($functionApp.DefaultHostName)"

Write-Host "`n⚠️  COMMON FIXES:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. RESTART THE FUNCTION APP (clears credential cache):" -ForegroundColor Cyan
Write-Host "   Restart-AzWebApp -ResourceGroupName '$ResourceGroupName' -Name '$($functionApp.Name)'" -ForegroundColor White
Write-Host ""
Write-Host "2. WAIT FOR RBAC PROPAGATION (5-10 minutes after deployment)" -ForegroundColor Cyan
Write-Host "   RBAC changes can take time to propagate across Azure" -ForegroundColor Gray
Write-Host ""
Write-Host "3. TEST MANAGED IDENTITY TOKEN:" -ForegroundColor Cyan
Write-Host "   curl -H 'Metadata:true' 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com' | jq" -ForegroundColor White
Write-Host "   (Run this from the Function App console in Azure Portal)" -ForegroundColor Gray
Write-Host ""
Write-Host "4. REDEPLOY FUNCTION APP:" -ForegroundColor Cyan
Write-Host "   cd FunctionApp" -ForegroundColor White
Write-Host "   func azure functionapp publish $($functionApp.Name) --powershell" -ForegroundColor White
Write-Host ""
