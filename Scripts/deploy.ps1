#region Alpenglow Alpha Deployment Script
<#
.SYNOPSIS
    Deploys Alpenglow Alpha infrastructure with security-isolated Function Apps

.DESCRIPTION
    Alpenglow Alpha Architecture:
    - Two Function Apps for security isolation:
      - func-alpenglow-data: Data collection with Graph API permissions
      - func-alpenglow-www: Dashboard only (minimal permissions)
    - 6 unified Cosmos DB containers (Serverless mode):
      - principals: users, groups, SPs, devices
      - resources: applications, Azure resources
      - edges: all relationships (with edgeType discriminator)
      - policies: CA policies, role policies, named locations
      - events: sign-ins, audits (90 day TTL)
      - audit: change audit trail (permanent)

.PARAMETER SubscriptionId
    Azure subscription ID
.PARAMETER TenantId
    Entra ID tenant ID
.PARAMETER ResourceGroupName
    Resource group name (default: rg-alpenglow-dev-001)
.PARAMETER Location
    Azure region (default: swedencentral)
.PARAMETER Environment
    Environment name (default: dev)
.PARAMETER BlobRetentionDays
    Blob retention in days (default: 7)
.PARAMETER WorkloadName
    Workload name for resources (default: alpenglow)

.PARAMETER DeployGremlin
    Deploy Gremlin graph database (default: false)

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "xxx" -TenantId "yyy"

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "xxx" -TenantId "yyy" -BlobRetentionDays 30
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
    [string]$ResourceGroupName = "rg-alpenglow-dev-001",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "swedencentral",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 365)]
    [int]$BlobRetentionDays = 7,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkloadName = "alpenglow",

    [Parameter(Mandatory=$false)]
    [bool]$DeployGremlin = $false
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
Write-DeploymentInfo "Deploy Gremlin" $(if ($DeployGremlin) { "Yes" } else { "No (deferred to V3.6)" })
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
            Project = 'Alpenglow-Alpha'
            DeployedBy = $env:USERNAME
            DeployedDate = (Get-Date -Format 'yyyy-MM-dd')
            Architecture = 'Alpenglow-Alpha'
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

$bicepFile = Join-Path $PSScriptRoot "main.bicep"

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
        -deployGremlin $DeployGremlin `
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

    # All required Graph API permissions for V3.5 collectors
    $requiredPermissions = @(
        "User.Read.All",
        "Group.Read.All",
        "Application.Read.All",
        "Directory.Read.All",
        "Device.Read.All",
        "AuditLog.Read.All",
        "Policy.Read.All",
        "RoleManagement.Read.All",
        "IdentityRiskEvent.Read.All",
        "PrivilegedAccess.Read.AzureAD",
        "PrivilegedAccess.Read.AzureADGroup",
        "PrivilegedAccess.Read.AzureResources",
        "UserAuthenticationMethod.Read.All",
        "IdentityRiskyUser.Read.All",
        "DeviceManagementConfiguration.Read.All"  # V3.5: Intune policies
    )

    # 2. Get the Service Principal of your Function App
    $managedIdentity = Get-AzADServicePrincipal -DisplayName $functionAppName -ErrorAction Stop

    # 3. Get the Microsoft Graph Service Principal (Global AppId: 00000003-0000-0000-c000-000000000000)
    $graphServicePrincipal = Get-AzADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop

    # 4. Get existing assignments to avoid duplicates
    $existingAssignments = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentity.Id

    # 5. Grant each permission
    $assignedCount = 0
    $skippedCount = 0

    foreach ($permissionName in $requiredPermissions) {
        # Find the specific ID for the application permission
        $appRole = $graphServicePrincipal.AppRole | Where-Object {
            $_.Value -eq $permissionName -and $_.AllowedMemberType -contains "Application"
        }

        if ($null -eq $appRole) {
            Write-Warning "  Could not find Graph permission: $permissionName"
            continue
        }

        # Check if assignment already exists
        $existingAssignment = $existingAssignments |
            Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphServicePrincipal.Id }

        if ($null -eq $existingAssignment) {
            try {
                New-AzADServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $managedIdentity.Id `
                    -ResourceId $graphServicePrincipal.Id `
                    -AppRoleId $appRole.Id | Out-Null
                Write-Host "  + $permissionName" -ForegroundColor Green
                $assignedCount++
            }
            catch {
                Write-Warning "  Failed to assign $permissionName : $_"
            }
        }
        else {
            Write-Host "  = $permissionName (already assigned)" -ForegroundColor Gray
            $skippedCount++
        }
    }

    Write-Host ""
    Write-DeploymentSuccess "Graph permissions: $assignedCount new, $skippedCount existing"
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
Write-Host "  V3.5 Containers:" -ForegroundColor Gray
Write-Host "    1. $($deployment.Outputs.cosmosContainerPrincipals.Value) - Users, groups, SPs, devices"
Write-Host "    2. $($deployment.Outputs.cosmosContainerResources.Value) - Applications, Azure resources"
Write-Host "    3. $($deployment.Outputs.cosmosContainerEdges.Value) - All relationships"
Write-Host "    4. $($deployment.Outputs.cosmosContainerPolicies.Value) - CA policies, role policies"
Write-Host "    5. $($deployment.Outputs.cosmosContainerEvents.Value) - Sign-ins, audits (90 day TTL)"
Write-Host "    6. $($deployment.Outputs.cosmosContainerAudit.Value) - Change audit trail"
Write-Host ""

# Function Apps (Security Isolated)
Write-Host "FUNCTION APPS (Security Isolated):" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Data Collection App:" -ForegroundColor Cyan
Write-DeploymentInfo "    Name" $deployment.Outputs.functionAppName.Value
Write-DeploymentInfo "    URL" "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
Write-DeploymentInfo "    Permissions" "Graph API (15), Cosmos DB, Storage"
Write-Host ""
Write-Host "  Dashboard App (www):" -ForegroundColor Cyan
Write-DeploymentInfo "    Name" $deployment.Outputs.functionAppWwwName.Value
Write-DeploymentInfo "    Dashboard" "https://$($deployment.Outputs.functionAppWwwName.Value).azurewebsites.net/api/dashboard"
Write-DeploymentInfo "    Permissions" "Cosmos DB connection string only (NO Graph API)"
Write-Host ""
Write-DeploymentInfo "Plan" "Shared Consumption (Y1 Dynamic)"
Write-Host ""

# Monitoring
Write-Host "MONITORING:" -ForegroundColor Yellow
Write-DeploymentInfo "Application Insights" $deployment.Outputs.appInsightsName.Value
Write-Host ""

# Identity
Write-Host "MANAGED IDENTITIES:" -ForegroundColor Yellow
Write-DeploymentInfo "Function App" $deployment.Outputs.functionAppIdentityPrincipalId.Value
Write-DeploymentInfo "Graph Permissions" "15 permissions assigned (see deploy.ps1 for list)"
Write-Host ""

#region FunctionApp Code Deployment
Write-Host ""
Write-Host "Deploying Function App code..." -ForegroundColor Yellow

try {
    # Check if Azure Functions Core Tools is installed
    $funcVersion = func --version 2>$null

    if (-not $funcVersion) {
        Write-Warning "Azure Functions Core Tools not found - skipping code deployment"
        Write-Host "  Install with: npm install -g azure-functions-core-tools@4"
        Write-Host "  Then deploy manually:"
        Write-Host "    cd FunctionApp-Data && func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell"
        Write-Host "    cd FunctionApp-www && func azure functionapp publish $($deployment.Outputs.functionAppWwwName.Value) --powershell"
    }
    else {
        # ===== Deploy Data Function App =====
        $dataAppPath = Join-Path $PSScriptRoot "..\FunctionApp-Data"

        if (-not (Test-Path $dataAppPath)) {
            throw "FunctionApp-Data directory not found at: $dataAppPath"
        }

        Write-Host ""
        Write-Host "  [1/2] Data Function App:" -ForegroundColor Cyan
        Write-Host "    Source: $dataAppPath"
        Write-Host "    Target: $($deployment.Outputs.functionAppName.Value)"

        Push-Location $dataAppPath
        try {
            func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell --no-build | Out-Host

            if ($LASTEXITCODE -eq 0) {
                Write-DeploymentSuccess "    Data Function App deployed"
            }
            else {
                Write-Warning "    Data app deployment completed with warnings"
            }
        }
        finally {
            Pop-Location
        }

        # ===== Deploy www Function App (Dashboard) =====
        $wwwAppPath = Join-Path $PSScriptRoot "..\FunctionApp-www"

        if (-not (Test-Path $wwwAppPath)) {
            throw "FunctionApp-www directory not found at: $wwwAppPath"
        }

        Write-Host ""
        Write-Host "  [2/2] www Function App (Dashboard):" -ForegroundColor Cyan
        Write-Host "    Source: $wwwAppPath"
        Write-Host "    Target: $($deployment.Outputs.functionAppWwwName.Value)"

        Push-Location $wwwAppPath
        try {
            func azure functionapp publish $($deployment.Outputs.functionAppWwwName.Value) --powershell --no-build | Out-Host

            if ($LASTEXITCODE -eq 0) {
                Write-DeploymentSuccess "    www Function App deployed"
            }
            else {
                Write-Warning "    www app deployment completed with warnings"
            }
        }
        finally {
            Pop-Location
        }

        Write-Host ""
        Write-DeploymentSuccess "Both Function Apps deployed successfully"
        Write-DeploymentInfo "Data App" "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
        Write-DeploymentInfo "Dashboard" "https://$($deployment.Outputs.functionAppWwwName.Value).azurewebsites.net/api/dashboard"
    }
}
catch {
    Write-Warning "Function App code deployment failed: $($_.Exception.Message)"
    Write-Host "  Deploy manually with:" -ForegroundColor Gray
    Write-Host "    cd FunctionApp-Data && func azure functionapp publish $($deployment.Outputs.functionAppName.Value) --powershell --no-build"
    Write-Host "    cd FunctionApp-www && func azure functionapp publish $($deployment.Outputs.functionAppWwwName.Value) --powershell --no-build"
}
#endregion
#endregion

#region Next Steps
Write-Host ""
Write-Host "=========================================="
Write-Host "NEXT STEPS (Required Manual Actions)"
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "2. TEST THE DEPLOYMENT" -ForegroundColor Yellow
Write-Host "   After Graph permissions are granted:"
Write-Host "   - Trigger via HTTP endpoint or wait for timer (every 6 hours)"
Write-Host "   - Check Application Insights for logs"
Write-Host "   - Verify data in Blob Storage (raw-data container)"
Write-Host "   - Verify blob outputs: principals.jsonl, resources.jsonl, edges.jsonl"
Write-Host "   - Verify Cosmos DB containers: principals, resources, edges, policies, audit"
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
    Architecture = 'Alpenglow-Alpha'

    Resources = @{
        StorageAccount = $deployment.Outputs.storageAccountName.Value
        FunctionAppData = $deployment.Outputs.functionAppName.Value
        FunctionAppWww = $deployment.Outputs.functionAppWwwName.Value
        CosmosDBAccount = $deployment.Outputs.cosmosDbAccountName.Value
        CosmosDatabase = $deployment.Outputs.cosmosDatabaseName.Value
        CosmosContainers = @{
            Principals = $deployment.Outputs.cosmosContainerPrincipals.Value
            Resources = $deployment.Outputs.cosmosContainerResources.Value
            Edges = $deployment.Outputs.cosmosContainerEdges.Value
            Policies = $deployment.Outputs.cosmosContainerPolicies.Value
            Events = $deployment.Outputs.cosmosContainerEvents.Value
            Audit = $deployment.Outputs.cosmosContainerAudit.Value
        }
        KeyVault = $deployment.Outputs.keyVaultName.Value
        ApplicationInsights = $deployment.Outputs.appInsightsName.Value
    }

    ManagedIdentities = @{
        FunctionAppData = $deployment.Outputs.functionAppIdentityPrincipalId.Value
        FunctionAppWww = $deployment.Outputs.functionAppWwwPrincipalId.Value
    }

    Endpoints = @{
        DataApp = "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
        Dashboard = "https://$($deployment.Outputs.functionAppWwwName.Value).azurewebsites.net/api/dashboard"
    }

    NextSteps = @{
        GraphAPIPermissions = "Auto-assigned to Data app only"
        SecurityIsolation = "www app has NO Graph API permissions"
    }
}

$infoPath = Join-Path $PSScriptRoot "deployment-info-alpenglow-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
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
Write-Host "Remember: Graph API permissions are auto-assigned. Test when ready." -ForegroundColor Yellow
Write-Host ""
#endregion