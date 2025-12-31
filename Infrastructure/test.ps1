# Get the managed identity
$managedIdentity = Get-AzADServicePrincipal -DisplayName "func-entrarisk-data-dev-36jut3xd6y2so"

# Get Graph service principal
$graphSP = Get-AzADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Find AuditLog.Read.All permission
$auditLogPermission = $graphSP.AppRole | Where-Object { 
    $_.Value -eq "AuditLog.Read.All" -and $_.AllowedMemberType -contains "Application" 
}

# Grant permission
New-AzADServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentity.Id `
    -ResourceId $graphSP.Id `
    -AppRoleId $auditLogPermission.Id

$f="VATqkmerGDlLnJcKAlGs8-lIBwiv50c3dDcJBzjcMe-rAzFuiw7Guw=="
$r = Invoke-RestMethod -Uri "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger?code=$f" -Method Post
Start-Sleep -Seconds 10
Invoke-RestMethod -Uri $r.statusQueryGetUri

# Keep checking until completion (run multiple times)
#Invoke-RestMethod -Uri $r.statusQueryGetUri

# Stream live logs (run in separate terminal)
#func azure functionapp logstream func-entrarisk-data-dev-36jut3xd6y2so

# After completion, check blob storage
az storage blob list --account-name stentrariskdev36jut3xd6y2so --container-name raw-data --auth-mode login --output table

# Check Cosmos DB for data
az cosmosdb sql container show --account-name cosno-entrarisk-dev-36jut3xd6y2so --database-name EntraData --name users_raw --resource-group rg-entrarisk-pilot-001

# Check status (keep running until Completed/Failed)
Invoke-RestMethod -Uri $r.statusQueryGetUri

# Application Insights - Recent traces
az monitor app-insights query `
  --app appi-entrarisk-dev-001 `
  --resource-group rg-entrarisk-pilot-001 `
  --analytics-query "traces | where timestamp > ago(10m) | order by timestamp desc | take 50" `
  --output table

# Application Insights - Errors
az monitor app-insights query `
  --app appi-entrarisk-dev-001 `
  --resource-group rg-entrarisk-pilot-001 `
  --analytics-query "exceptions | where timestamp > ago(10m) | project timestamp, message, outerMessage" `
  --output table

# Application Insights - Function executions
az monitor app-insights query `
  --app appi-entrarisk-dev-001 `
  --resource-group rg-entrarisk-pilot-001 `
  --analytics-query "requests | where timestamp > ago(10m) | project timestamp, name, duration, success" `
  --output table

# Stream live logs
func azure functionapp logstream func-entrarisk-data-dev-36jut3xd6y2so

# Check blob storage
az storage blob list `
  --account-name stentrariskdev36jut3xd6y2so `
  --container-name raw-data `
  --auth-mode login `
  --output table

# Check Cosmos DB document count
az cosmosdb sql container throughput show `
  --account-name cosno-entrarisk-dev-36jut3xd6y2so `
  --database-name EntraData `
  --name users_raw `
  --resource-group rg-entrarisk-pilot-001

# View function app logs (Azure Portal)
# https://portal.azure.com -> func-entrarisk-data-dev-36jut3xd6y2so -> Log stream