# placeholder resources
# Tested pattern: ARM deployment for Logic App, Az cmdlets for the rest.

$rg       = "rg-test-data"
$location = "westeurope"
$unique   = (Get-Random -Maximum 99999)

$logicAppName   = "la-detect-$unique"
$planName       = "asp-free-$unique"
$webAppName     = "webdetect$unique"      # web apps must be globally unique + lowercase
$automationName = "aa-detect-$unique"

# -----------------------------
# Resource group
# -----------------------------
if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $rg -Location $location | Out-Null
}

# -----------------------------
# Logic App (Consumption)
# -----------------------------
$logicAppTemplate = @{
    '$schema'        = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion  = '1.0.0.0'
    resources       = @(
        @{
            type       = 'Microsoft.Logic/workflows'
            apiVersion = '2019-05-01'
            name       = $logicAppName
            location   = $location
            properties = @{
                state      = 'Enabled'
                definition = @{
                    '$schema'      = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
                    contentVersion = '1.0.0.0'
                    triggers       = @{}
                    actions        = @{}
                    outputs        = @{}
                }
            }
        }
    )
}

New-AzResourceGroupDeployment `
    -ResourceGroupName $rg `
    -TemplateObject $logicAppTemplate `
    -Mode Incremental | Out-Null

# -----------------------------
# App Service Plan (Free F1)
# -----------------------------
New-AzAppServicePlan `
    -ResourceGroupName $rg `
    -Name $planName `
    -Location $location `
    -Tier Free `
    -WorkerSize Small `
    -NumberofWorkers 1 | Out-Null

# -----------------------------
# Web App (empty placeholder)
# -----------------------------
New-AzWebApp `
    -ResourceGroupName $rg `
    -Name $webAppName `
    -Location $location `
    -AppServicePlan $planName | Out-Null

# -----------------------------
# Automation Account (Free)
# -----------------------------
New-AzAutomationAccount `
    -ResourceGroupName $rg `
    -Name $automationName `
    -Location $location `
    -Plan Free | Out-Null

# -----------------------------
# Output
# -----------------------------
[PSCustomObject]@{
    ResourceGroup     = $rg
    LogicApp          = $logicAppName
    WebApp            = $webAppName
    AppServicePlan    = $planName
    AutomationAccount = $automationName
}
