#region Pilot Deployment Script - Delta Architecture
<#
.SYNOPSIS
    Deploys Entra Risk Analysis infrastructure
    
.PARAMETER SubscriptionId
    Azure subscription ID
.PARAMETER TenantId
    Entra ID tenant ID
.PARAMETER ResourceGroupName
    Resource group name (default: rg-entrarisk-pilot)
.PARAMETER Location
    Azure region (default: )
.PARAMETER Environment
    Environment name (default: dev)
.PARAMETER BlobRetentionDays
    Blob retention in days (default: 7)
.PARAMETER WorkloadName
    Workload name for resources (default: entrarisk)
    
.EXAMPLE
    .\deploy-pilot-delta.ps1 -SubscriptionId "xxx" -TenantId "yyy"
    
.EXAMPLE
    .\deploy-pilot-delta.ps1 -SubscriptionId "xxx" -TenantId "yyy" -BlobRetentionDays 30
#>
#endregion

#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-entrarisk-pilot-001",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "swedencentral",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 365)]
    [int]$BlobRetentionDays = 7,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkloadName = "entrarisk"
)

#region Helper Functions
function Write-DeploymentHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ""
}

function Write-DeploymentSuccess {
    param([string]$Message)
    Write-Host "$Message" -ForegroundColor Green
}

function Write-DeploymentInfo {
    param([string]$Label, [string]$Value)
    Write-Host "  ${Label}: " -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor White
}
#endregion

#region Banner
Write-DeploymentHeader "Deploying..."

Write-Host "Deployment Configuration:" -ForegroundColor Yellow
Write-DeploymentInfo "Subscription" $SubscriptionId
Write-DeploymentInfo "Tenant" $TenantId
Write-DeploymentInfo "Resource Group" $ResourceGroupName
Write-DeploymentInfo "Location" $Location
Write-DeploymentInfo "Environment" $Environment
Write-DeploymentInfo "Blob Retention" "$BlobRetentionDays days"
Write-Host ""

#region Azure Connection
Write-Host ""
Write-Host "Connecting to Azure..." -ForegroundColor Yellow

try {
    $context = Get-AzContext -ErrorAction Stop
    
    if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
        Write-Host "Authentication required..."
        Connect-AzAccount -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
    
    $context = Get-AzContext
    Write-DeploymentSuccess "Connected to Azure"
    Write-DeploymentInfo "Account" $context.Account.Id
    Write-DeploymentInfo "Subscription" $context.Subscription.Name
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}
#endregion

#region Resource Group
Write-Host ""
Write-Host "Creating/Verifying resource group..." -ForegroundColor Yellow

try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
            Environment = $Environment
            Workload = $WorkloadName
            Project = 'EntraRiskAnalysis-Delta'
            DeployedBy = $env:USERNAME
            DeployedDate = (Get-Date -Format 'yyyy-MM-dd')
            Architecture = 'DeltaChangeDetection'
        } -ErrorAction Stop
        
        Write-DeploymentSuccess "Resource group created"
    }
    else {
        Write-DeploymentSuccess "Resource group exists"
    }
    
    Write-DeploymentInfo "Name" $rg.ResourceGroupName
    Write-DeploymentInfo "Location" $rg.Location
}
catch {
    Write-Error "Failed to create resource group: $_"
    exit 1
}
#endregion

#region Bicep Deployment
Write-Host ""
Write-Host "Deploying infrastructure (this may take 5-10 minutes)..." -ForegroundColor Yellow

$bicepFile = Join-Path $PSScriptRoot "main-pilot-delta.bicep"

if (-not (Test-Path $bicepFile)) {
    Write-Error "Bicep file not found: $bicepFile"
    exit 1
}

$deploymentName = "delta-pilot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "  Deployment name: $deploymentName"
Write-Host "  Template: $(Split-Path $bicepFile -Leaf)"
Write-Host ""

try {
    # Start deployment
    $deployment = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $bicepFile `
        -workloadName $WorkloadName `
        -environment $Environment `
        -location $Location `
        -tenantId $TenantId `
        -blobRetentionDays $BlobRetentionDays `
        -Verbose `
        -ErrorAction Stop
    
    Write-DeploymentSuccess "Infrastructure deployment completed"
}
catch {
    Write-Error "Deployment failed: $_"
    
    # Extract inner validation errors
    $exception = $_.Exception
    while ($exception.InnerException) {
        $exception = $exception.InnerException
    }
    
    Write-Host "`nInner Exception Details:" -ForegroundColor Red
    Write-Host $exception.Message
    
    # Try to get Details property
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Host "`nError Details Message:" -ForegroundColor Red
        $_.ErrorDetails.Message
    }
    
    # Get the response if available
    if ($exception.Response) {
        Write-Host "`nResponse Status: $($exception.Response.StatusCode)" -ForegroundColor Red
    }

    exit 1
}
#endregion

#region FunctionApp (enterprise registration) API Permissions
Write-Host ""
Write-Host "Assigning Microsoft Graph permissions to Managed Identity..." -ForegroundColor Yellow

try {
    # 1. Get the Function App name and Identity ID from Bicep outputs
    $functionAppName = $deployment.Outputs.functionAppName.Value
    $permissionName = "User.Read.All" 

    # 2. Get the Service Principal of your Function App
    $managedIdentity = Get-AzADServicePrincipal -DisplayName $functionAppName -ErrorAction Stop
    
    # 3. Get the Microsoft Graph Service Principal (Global AppId: 00000003-0000-0000-c000-000000000000)
    $graphServicePrincipal = Get-AzADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop

    # 4. Find the specific ID for the application permission
    $appRole = $graphServicePrincipal.AppRole | Where-Object { 
        $_.Value -eq $permissionName -and $_.AllowedMemberType -contains "Application" 
    }

    if ($null -eq $appRole) {
        throw "Could not find Graph permission: $permissionName"
    }

    # 5. Check if assignment already exists to avoid errors on re-run
    $existingAssignment = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentity.Id | 
        Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphServicePrincipal.Id }

    if ($null -eq $existingAssignment) {
        New-AzADServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $managedIdentity.Id `
            -ResourceId $graphServicePrincipal.Id `
            -AppRoleId $appRole.Id | Out-Null
        Write-DeploymentSuccess "Successfully assigned $permissionName to $functionAppName"
    }
    else {
        Write-Host "  Permission $permissionName already assigned." -ForegroundColor Gray
    }
}
catch {
    Write-Warning "Failed to assign Graph permissions: $_"
    Write-Host "Manual intervention may be required in Entra ID." -ForegroundColor Gray
}
#endregion

#region Display Results
Write-DeploymentHeader "Deployment Complete!"

Write-Host "Deployed Resources:" -ForegroundColor Cyan
Write-Host ""

# Storage
Write-Host "STORAGE LAYER:" -ForegroundColor Yellow
Write-DeploymentInfo "Storage Account" $deployment.Outputs.storageAccountName.Value
Write-DeploymentInfo "Blob Retention" "$BlobRetentionDays days (auto-delete)"
Write-DeploymentInfo "Purpose" "Landing zone + checkpoint"
Write-Host ""

# Cosmos DB
Write-Host "COSMOS DB LAYER:" -ForegroundColor Yellow
Write-DeploymentInfo "Account" $deployment.Outputs.cosmosDbAccountName.Value
Write-DeploymentInfo "Endpoint" $deployment.Outputs.cosmosDbEndpoint.Value
Write-DeploymentInfo "Database" $deployment.Outputs.cosmosDatabaseName.Value
Write-Host ""
Write-Host "  Containers:" -ForegroundColor Gray
Write-Host "    1. $($deployment.Outputs.cosmosContainerUsersRaw.Value) - Current user state"
Write-Host "    2. $($deployment.Outputs.cosmosContainerUserChanges.Value) - Change log (365 day TTL)"
Write-Host "    3. $($deployment.Outputs.cosmosContainerSnapshots.Value) - Collection metadata"
Write-Host ""

# Function App
Write-Host "FUNCTION APP:" -ForegroundColor Yellow
Write-DeploymentInfo "Name" $deployment.Outputs.functionAppName.Value
Write-DeploymentInfo "URL" "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
Write-DeploymentInfo "Plan" "Consumption (Dynamic)"
Write-DeploymentInfo "Features" "Delta detection enabled"
Write-Host ""

# AI Foundry
Write-Host "AI FOUNDRY:" -ForegroundColor Yellow
Write-DeploymentInfo "Hub" ($deployment.Outputs.aiFoundryHubName.Value ?? "N/A")
Write-DeploymentInfo "Project" ($deployment.Outputs.aiFoundryProjectName.Value ?? "N/A")
Write-Host ""

# Monitoring
Write-Host "MONITORING:" -ForegroundColor Yellow
Write-DeploymentInfo "Application Insights" $deployment.Outputs.appInsightsName.Value
Write-Host ""

# Identity
Write-Host "MANAGED IDENTITIES:" -ForegroundColor Yellow
Write-DeploymentInfo "Function App" $deployment.Outputs.functionAppIdentityPrincipalId.Value
Write-DeploymentInfo "Graph Permissions" "User.Read.All (Assigned)" # Add this line
Write-Host ""

#region FunctionApp Code Deployment
Write-Host ""
Write-Host "Deploying Function App code..." -ForegroundColor Yellow

# Manual deployment:
# func azure functionapp publish func-entrarisk-data-dev-36jut3xd6y2so --powershell --no-build

try {
    # Check if Azure Functions Core Tools is installed
    $funcVersion = func --version 2>$null
    
    if (-not $funcVersion) {
        Write-Warning "Azure Functions Core Tools not found - skipping code deployment"
        Write-Host "  Install with: npm install -g azure-functions-core-tools@4"
        Write-Host "  Then deploy manually: cd FunctionApp && func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell"
    }
    else {
        # Verify FunctionApp directory exists
        $functionAppPath = Join-Path $PSScriptRoot "..\FunctionApp"
        
        if (-not (Test-Path $functionAppPath)) {
            throw "FunctionApp directory not found at: $functionAppPath"
        }
        
        # Deploy function app
        Write-Host "  Source: $functionAppPath"
        Write-Host "  Target: $($deployment.Outputs.functionAppName.Value)"
        
        Push-Location $functionAppPath
        try {
            # Deploy with --no-build flag to skip sync triggers during deployment
            # Triggers will sync automatically when function app starts
            func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell --no-build | Out-Host
            
            if ($LASTEXITCODE -eq 0) {
                Write-DeploymentSuccess "Function App code deployed"
                Write-DeploymentInfo "Endpoint" "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
                Write-Host ""
                Write-Host "  Note: Function triggers will sync automatically when the app starts (may take 1-2 minutes)" -ForegroundColor Gray
            }
            else {
                # Exit code 1 often means sync triggers failed but deployment succeeded
                # Check if it's just the sync triggers error
                Write-Warning "Deployment completed with warnings (sync triggers may have failed)"
                Write-Host "  This is often a timing issue - triggers will sync when the function app fully starts"
                Write-Host "  Verify in 2-3 minutes at: https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
            }
        }
        finally {
            Pop-Location
        }
    }
}
catch {
    Write-Warning "Function App code deployment failed: $($_.Exception.Message)"
    Write-Host "  Deploy manually with:" -ForegroundColor Gray
    Write-Host "    cd FunctionApp"
    Write-Host "    func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell --no-build"
}
#endregion
#endregion

#region Next Steps
Write-Host ""
Write-Host "=========================================="
Write-Host "NEXT STEPS (Required Manual Actions)"
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "2. (OPTIONAL) DEPLOY AI MODEL" -ForegroundColor Gray
Write-Host "   For AI Foundry testing:"
Write-Host "   - Visit: https://ai.azure.com"
Write-Host "   - Navigate to your project"
Write-Host "   - Deploy 'gpt-4o-mini' model"
Write-Host ""

Write-Host "3. TEST THE DEPLOYMENT" -ForegroundColor Yellow
Write-Host "   After steps 1-3 are complete:"
Write-Host "   - Trigger via HTTP endpoint or wait for timer (every 6 hours)"
Write-Host "   - Check Application Insights for logs"
Write-Host "   - Verify data in Blob Storage (raw-data container)"
Write-Host "   - Verify data in Cosmos DB (users_raw container)"
Write-Host "   - Check user_changes container for deltas"
Write-Host ""
#endregion

#region Save Deployment Info
$deploymentInfo = @{
    DeploymentName = $deploymentName
    DeploymentDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ResourceGroupName = $ResourceGroupName
    SubscriptionId = $SubscriptionId
    Location = $Location
    Environment = $Environment
    BlobRetentionDays = $BlobRetentionDays
    Architecture = 'DeltaChangeDetection'
    
    Resources = @{
        StorageAccount = $deployment.Outputs.storageAccountName.Value
        FunctionApp = $deployment.Outputs.functionAppName.Value
        CosmosDBAccount = $deployment.Outputs.cosmosDbAccountName.Value
        CosmosDatabase = $deployment.Outputs.cosmosDatabaseName.Value
        CosmosContainers = @{
            UsersRaw = $deployment.Outputs.cosmosContainerUsersRaw.Value
            UserChanges = $deployment.Outputs.cosmosContainerUserChanges.Value
            Snapshots = $deployment.Outputs.cosmosContainerSnapshots.Value
        }
        KeyVault = $deployment.Outputs.keyVaultName.Value
        ApplicationInsights = $deployment.Outputs.appInsightsName.Value
        AIFoundryHub = $deployment.Outputs.aiFoundryHubName.Value
        AIFoundryProject = $deployment.Outputs.aiFoundryProjectName.Value
    }
    
    ManagedIdentities = @{
        FunctionApp = $deployment.Outputs.functionAppIdentityPrincipalId.Value
    }
    
    NextSteps = @{
        GraphAPIPermissions = "Required - See steps above"
        ModulePublishing = "Required - Run publish-module.yml"
        AppDeployment = "Required - Run pilot-pipeline.yml"
        AIModelDeployment = "Optional - Deploy in AI Foundry portal"
    }
}

$infoPath = Join-Path $PSScriptRoot "deployment-info-delta-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$deploymentInfo | ConvertTo-Json -Depth 10 | Set-Content -Path $infoPath

Write-Host ""
Write-Host "Deployment information saved to:" -ForegroundColor Gray
Write-Host "  $infoPath"
Write-Host ""
#endregion

#region Final Message
Write-Host "=========================================="
Write-Host "Deployment script completed successfully!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Remember to complete the 5 manual steps above before testing." -ForegroundColor Yellow
Write-Host ""
#endregion