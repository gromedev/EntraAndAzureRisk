# -----------------------------
# 1. Configuration & Variables
# -----------------------------
$rg       = "rg-test-data"
$location = "westeurope"
$unique   = (Get-Random -Maximum 99999)

# Resource Names
$uamiName       = "id-detect-$unique"
$kvName         = "kv-detect-$unique"
$aksName        = "aks-detect-$unique"
$vmName         = "vm-detect-$unique"
$sqlServerName  = "sql-detect-$unique"
$sqlDBName      = "sqldb-detect"
$acrName        = "acrdetect$unique"
$storageName    = "stdetect$unique"
$logicAppName   = "la-detect-$unique"
$planName       = "asp-free-$unique"
$webAppName     = "webdetect$unique"
$automationName = "aa-detect-$unique"

# Shared Credentials
$adminUser = "azureuser"
$adminPass = ConvertTo-SecureString "P@ssw0rd1234!!" -AsPlainText -Force
$creds     = New-Object System.Management.Automation.PSCredential($adminUser, $adminPass)

# -----------------------------
# 2. Resource Group & Identity
# -----------------------------
if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Resource Group: $rg..." -ForegroundColor Cyan
    New-AzResourceGroup -Name $rg -Location $location | Out-Null
}

Write-Host "Creating User-Assigned Managed Identity..." -ForegroundColor Cyan
$uami = New-AzUserAssignedIdentity -ResourceGroupName $rg -Name $uamiName -Location $location

# -----------------------------
# 3. Security (Key Vault, Secrets, Certificates)
# -----------------------------
Write-Host "Deploying Key Vault with Secret and Certificate..." -ForegroundColor Cyan
$kv = New-AzKeyVault -VaultName $kvName -ResourceGroupName $rg -Location $location

# Add a Secret
Set-AzKeyVaultSecret -VaultName $kvName -Name "TestSecret" -SecretValue (ConvertTo-SecureString "DetectorTest123" -AsPlainText -Force) | Out-Null

# Add a Self-Signed Certificate
$policy = New-AzKeyVaultCertificatePolicy -SubjectName "CN=TestCert" -IssuerName Self -ValidityInMonths 12
Add-AzKeyVaultCertificate -VaultName $kvName -Name "TestCert" -CertificatePolicy $policy | Out-Null

# -----------------------------
# 4. Compute (VM & AKS)
# -----------------------------
Write-Host "Deploying B1ls Linux VM (with Identity)..." -ForegroundColor Cyan
New-AzVM `
    -ResourceGroupName $rg `
    -Name $vmName `
    -Location $location `
    -Image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest" `
    -Size "Standard_B1ls" `
    -Credential $creds `
    -UserAssignedIdentityId $uami.Id `
    -StorageAccountType "Standard_LRS" | Out-Null

Write-Host "Deploying AKS Cluster (Free Tier, takes ~5-7 mins)..." -ForegroundColor Cyan
New-AzAksCluster -ResourceGroupName $rg -Name $aksName -Location $location -NodeCount 1 -NodeVmSize "Standard_B2s" -SkuTier Free -GenerateSshKey | Out-Null

# -----------------------------
# 5. Data & Registry (SQL, ACR, Storage)
# -----------------------------
Write-Host "Deploying SQL Database, ACR, and Storage..." -ForegroundColor Cyan
New-AzContainerRegistry -ResourceGroupName $rg -Name $acrName -Location $location -Sku "Basic" | Out-Null
New-AzSqlServer -ResourceGroupName $rg -Location $location -ServerName $sqlServerName -ServerVersion "12.0" -SqlAdministratorCredentials $creds | Out-Null
New-AzSqlDatabase -ResourceGroupName $rg -ServerName $sqlServerName -DatabaseName $sqlDBName -Edition "Basic" | Out-Null
New-AzStorageAccount -ResourceGroupName $rg -Name $storageName -Location $location -SkuName "Standard_LRS" -Kind "StorageV2" | Out-Null

# -----------------------------
# 6. Serverless (Logic App, Web App, Automation)
# -----------------------------
Write-Host "Deploying Serverless & Web placeholders..." -ForegroundColor Cyan
# Logic App (ARM Template approach)
$logicAppTemplate = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'; contentVersion = '1.0.0.0'
    resources = @(@{
        type = 'Microsoft.Logic/workflows'; apiVersion = '2019-05-01'; name = $logicAppName; location = $location
        properties = @{ state = 'Enabled'; definition = @{ '$schema' = '...'; contentVersion = '1.0.0.0'; triggers = @{}; actions = @{}; outputs = @{} } }
    })
}
New-AzResourceGroupDeployment -ResourceGroupName $rg -TemplateObject $logicAppTemplate -Mode Incremental | Out-Null

# Web App with Managed Identity
New-AzAppServicePlan -ResourceGroupName $rg -Name $planName -Location $location -Tier Free | Out-Null
Set-AzWebApp -ResourceGroupName $rg -Name $webAppName -AssignIdentity $true -UserAssignedIdentityId $uami.Id -Location $location -AppServicePlan $planName | Out-Null

# Automation Account
New-AzAutomationAccount -ResourceGroupName $rg -Name $automationName -Location $location -Plan Free | Out-Null

# -----------------------------
# 7. Final Output
# -----------------------------
Write-Host "`nAll 11 Resource Types Deployed!" -ForegroundColor Green
[PSCustomObject]@{
    ResourceGroup      = $rg
    AKS_Cluster        = $aksName
    VM_B1ls            = $vmName
    Managed_Identity   = $uamiName
    KeyVault_Name      = $kvName
    SQL_Database       = $sqlDBName
    Container_Registry = $acrName
}