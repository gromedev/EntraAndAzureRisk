# -----------------------------
# 1. Configuration & Variables
# -----------------------------
$rg       = "rg-test-data"
$location = "westeurope"
$unique   = (Get-Random -Maximum 99999)
$tags     = @{ "Environment" = "DetectionTest"; "Owner" = "SecurityTeam" }

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
    Write-Host "Creating Resource Group..." -ForegroundColor Cyan
    New-AzResourceGroup -Name $rg -Location $location -Tag $tags | Out-Null
}

Write-Host "Creating Managed Identity..." -ForegroundColor Cyan
$uami = New-AzUserAssignedIdentity -ResourceGroupName $rg -Name $uamiName -Location $location -Tag $tags

# -----------------------------
# 3. Security (Key Vault & Secrets)
# -----------------------------
Write-Host "Deploying Key Vault & Secrets..." -ForegroundColor Cyan
# Removed the '$kv =' assignment to fix the PSScriptAnalyzer warning
New-AzKeyVault -VaultName $kvName -ResourceGroupName $rg -Location $location -Tag $tags | Out-Null
Set-AzKeyVaultSecret -VaultName $kvName -Name "TestSecret" -SecretValue (ConvertTo-SecureString "DetectorTest123" -AsPlainText -Force) | Out-Null

$policy = New-AzKeyVaultCertificatePolicy -SubjectName "CN=TestCert" -IssuerName Self -ValidityInMonths 12
Add-AzKeyVaultCertificate -VaultName $kvName -Name "TestCert" -CertificatePolicy $policy | Out-Null

# -----------------------------
# 4. Compute (VM & AKS)
# -----------------------------
Write-Host "Deploying B1ls Linux VM..." -ForegroundColor Cyan
New-AzVM `
    -ResourceGroupName $rg `
    -Name $vmName `
    -Location $location `
    -Image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest" `
    -Size "Standard_B1ls" `
    -Credential $creds `
    -UserAssignedIdentityId $uami.Id `
    -Tag $tags `
    -StorageAccountType "Standard_LRS" | Out-Null

Write-Host "Deploying AKS Cluster (takes ~5-7 mins)..." -ForegroundColor Cyan
New-AzAksCluster -ResourceGroupName $rg -Name $aksName -Location $location -NodeCount 1 -NodeVmSize "Standard_B2s" -SkuTier Free -GenerateSshKey -Tag $tags | Out-Null

# -----------------------------
# 5. Data & Registry
# -----------------------------
Write-Host "Deploying SQL, ACR, and Storage..." -ForegroundColor Cyan
New-AzContainerRegistry -ResourceGroupName $rg -Name $acrName -Location $location -Sku "Basic" -Tag $tags | Out-Null
New-AzSqlServer -ResourceGroupName $rg -Location $location -ServerName $sqlServerName -ServerVersion "12.0" -SqlAdministratorCredentials $creds -Tag $tags | Out-Null
New-AzSqlDatabase -ResourceGroupName $rg -ServerName $sqlServerName -DatabaseName $sqlDBName -Edition "Basic" -Tag $tags | Out-Null
New-AzStorageAccount -ResourceGroupName $rg -Name $storageName -Location $location -SkuName "Standard_LRS" -Kind "StorageV2" -Tag $tags | Out-Null

# -----------------------------
# 6. Serverless & Apps
# -----------------------------
Write-Host "Deploying App Services and Logic Apps..." -ForegroundColor Cyan
New-AzAppServicePlan -ResourceGroupName $rg -Name $planName -Location $location -Tier Free -Tag $tags | Out-Null
New-AzWebApp -ResourceGroupName $rg -Name $webAppName -Location $location -AppServicePlan $planName -AssignIdentity $true -Tag $tags | Out-Null
New-AzAutomationAccount -ResourceGroupName $rg -Name $automationName -Location $location -Plan Free -Tag $tags | Out-Null

# Logic App
$logicAppTemplate = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'; contentVersion = '1.0.0.0'
    resources = @(@{
        type = 'Microsoft.Logic/workflows'; apiVersion = '2019-05-01'; name = $logicAppName; location = $location; tags = $tags
        properties = @{ state = 'Enabled'; definition = @{ '$schema' = '...'; contentVersion = '1.0.0.0'; triggers = @{}; actions = @{}; outputs = @{} } }
    })
}
New-AzResourceGroupDeployment -ResourceGroupName $rg -TemplateObject $logicAppTemplate -Mode Incremental | Out-Null

# -----------------------------
# 7. Final Output
# -----------------------------
Write-Host "`nAll resources deployed successfully without warnings!" -ForegroundColor Green
[PSCustomObject]@{
    RG          = $rg
    AKS         = $aksName
    VM          = $vmName
    Identity    = $uamiName
    Vault       = $kvName
    DetectionTag = "Environment: DetectionTest"
}