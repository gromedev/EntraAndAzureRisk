# DevOps Cheat Sheet

Quick reference for deploying, testing, and monitoring the Alpenglow solution.

## Monitoring script
```powershell

$uri = "https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/api/httptrigger?code=OPwmPmmOTDJXigyvjfhT2ERXrK9sY7qY5xRVJ5DZT28TAzFuHb0BKg=="
$body = @{ action = "start" } | ConvertTo-Json

Write-Host "Starting orchestration..."
$response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
$STATUS_URI = $response.statusQueryGetUri

Write-Host "Monitoring orchestration: $($response.id)"
Write-Host ""

$startTime = Get-Date

while ($true) {
    Start-Sleep -Seconds 10
    
    $status = Invoke-RestMethod -Uri $STATUS_URI
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    
    $currentActivities = $status.historyEvents | Where-Object { 
        $_.EventType -eq 'TaskScheduled' -and 
        -not ($status.historyEvents | Where-Object { 
            $_.EventType -eq 'TaskCompleted' -and 
            $_.TaskScheduledId -eq $_.EventId 
        })
    } | ForEach-Object {
        $activityStart = [DateTime]$_.Timestamp
        $activityElapsed = [int]((Get-Date).ToUniversalTime() - $activityStart).TotalSeconds
        "$($_.Name) (${activityElapsed}s)"
    }
    
    $activityList = if ($currentActivities) { 
        $currentActivities -join ', ' 
    } else { 
        'None' 
    }
    
    Write-Host "${elapsed}s: $($status.runtimeStatus) | Running: $activityList"
    
    if ($status.runtimeStatus -in @('Completed', 'Failed')) { 
        break 
    }
}

Write-Host "Orchestration $($status.runtimeStatus.ToLower()) in ${elapsed}s"

```

### One liner

```powershell

$STATUS_URI; $elapsed = [int]((Get-Date) - $startTime).TotalSeconds; $currentActivities = $status.historyEvents | Where-Object { $_.EventType -eq 'TaskScheduled' -and -not ($status.historyEvents | Where-Object { $_.EventType -eq 'TaskCompleted' -and $_.TaskScheduledId -eq $_.EventId }) } | ForEach-Object { $activityStart = [DateTime]$_.Timestamp; $activityElapsed = [int]((Get-Date).ToUniversalTime() - $activityStart).TotalSeconds; "$($_.Name) (${activityElapsed}s)" }; $activityList = if ($currentActivities) { $currentActivities -join ', ' } else { 'None' }; Write-Host "${elapsed}s: $($status.runtimeStatus) | Running: $activityList"; if ($status.runtimeStatus -in @('Completed', 'Failed')) { break } 

```
---

## Variables (set these first)
```powershell
$FUNC_APP = "func-entrariskv35-data-dev-enkqnnv64liny"
$STORAGE_ACCOUNT = "stentrariskv35devenkqnnv"
$COSMOS_ACCOUNT = "cosno-entrariskv35-dev-enkqnnv64liny"
$RG = "rg-entrarisk-v35-001"
$DATABASE = "EntraData"
```

---

## 1. Deploy Changes to Azure
```powershell
Push-Location "/Users/thomas/git/GitHub/EntraAndAzureRisk/FunctionApp"
func azure functionapp publish $FUNC_APP --powershell
Pop-Location
```

---

## 2. Wipe Test Data (Fresh Start)

### Wipe Blob Storage
```powershell
az storage blob delete-batch --source raw-data --account-name $STORAGE_ACCOUNT --auth-mode login
```

### Wipe Cosmos DB (delete and recreate containers)
```powershell
$containers = @('principals', 'resources', 'edges', 'policies', 'events', 'audit')

foreach ($container in $containers) {
    az cosmosdb sql container delete -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n $container --yes
}

az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n principals --partition-key-path "/objectId" --throughput 400 -o none
az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n resources --partition-key-path "/objectId" --throughput 400 -o none
az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n edges --partition-key-path "/edgeType" --throughput 400 -o none
az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n policies --partition-key-path "/objectId" --throughput 400 -o none
az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n events --partition-key-path "/eventId" --throughput 400 -o none
az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n audit --partition-key-path "/auditDate" --throughput 400 -o none
```

---

## 3. Run Orchestration

### Get Function Key
```powershell
$FUNC_KEY = az functionapp function keys list -g $RG -n $FUNC_APP --function-name HttpTrigger --query "default" -o tsv
```

### Trigger Full Sync
```powershell
$uri = "https://${FUNC_APP}.azurewebsites.net/api/httptrigger?code=${FUNC_KEY}"
$body = @{ action = "start" } | ConvertTo-Json
$response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
$STATUS_URI = $response.statusQueryGetUri
```

### Trigger Delta Sync
```powershell
$uri = "https://${FUNC_APP}.azurewebsites.net/api/httptrigger?code=${FUNC_KEY}"
$body = @{ 
    action = "start"
    useDelta = $true
} | ConvertTo-Json
$response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
$STATUS_URI = $response.statusQueryGetUri
```

### Poll for Completion
```powershell
$status = Invoke-RestMethod -Uri $STATUS_URI
$status | Select-Object runtimeStatus, output | ConvertTo-Json
```

---

## 4. Monitor Performance

### Watch Orchestration Status (loop)
```powershell
$startTime = Get-Date
while ($true) {
    Start-Sleep -Seconds 10
    $status = Invoke-RestMethod -Uri $STATUS_URI
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    Write-Host "${elapsed}s: $($status.runtimeStatus)"
    if ($status.runtimeStatus -in @('Completed', 'Failed')) { break }
}
```

### Get Indexing Statistics from Completed Run
```powershell
$status = Invoke-RestMethod -Uri $STATUS_URI
$status.output.Indexing.PSObject.Properties | ForEach-Object {
    $stats = $_.Value
    "$($_.Name): Total=$($stats.Total), New=$($stats.New), Modified=$($stats.Modified), Writes=$($stats.CosmosWrites)"
}
```

### Get Phase Timing (CollectRelationships)
```powershell
$status = Invoke-RestMethod -Uri $STATUS_URI
$status.output.Collection.Edges.Summary.phaseTiming | ConvertTo-Json
```

---

## 5. Check Blob Storage

### List Recent Blobs
```powershell
$blobs = az storage blob list --container-name raw-data --account-name $STORAGE_ACCOUNT --auth-mode login --query "[].{name:name, size:properties.contentLength}" | ConvertFrom-Json
$blobs | Select-Object -First 20 | Format-Table
```

### Download and Count Edges
```powershell
$latest = (az storage blob list --container-name raw-data --account-name $STORAGE_ACCOUNT --auth-mode login --query "[0].name" -o tsv).Split('/')[0]
az storage blob download --container-name raw-data --account-name $STORAGE_ACCOUNT --name "$latest/$latest-edges.jsonl" --file "/tmp/edges.jsonl" --auth-mode login -o none
(Get-Content "/tmp/edges.jsonl").Count
```

### Edge Types Distribution
```powershell
$edges = Get-Content "/tmp/edges.jsonl" | ForEach-Object { ($_ | ConvertFrom-Json).edgeType }
$edges | Group-Object | Sort-Object Count -Descending | Select-Object Name, Count
```

---

## 6. Dashboard Validation

### Get Dashboard HTML
```powershell
$DASH_KEY = az functionapp function keys list -g $RG -n $FUNC_APP --function-name Dashboard --query "default" -o tsv
$dashUri = "https://${FUNC_APP}.azurewebsites.net/api/dashboard?code=${DASH_KEY}"
Invoke-WebRequest -Uri $dashUri -OutFile "/tmp/dashboard.html"
```

### Check Dashboard Size
```powershell
$fileInfo = Get-Item "/tmp/dashboard.html"
"Size: {0:N2} MB" -f ($fileInfo.Length / 1MB)
```

### Extract Debug Metrics
```powershell
$content = Get-Content "/tmp/dashboard.html" -Raw
if ($content -match 'Changes:.*?del') { $Matches[0] }
```

---

## 7. Make Test Changes
```powershell
& pwsh -NoProfile -File "/Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Invoke-AlpenglowTestData.ps1" -NonInteractive -Action Changes
```

---

## 8. View Application Insights Logs
```powershell
# Recent logs (last 15 min)
$query = "traces | where timestamp > ago(15m) | order by timestamp desc | take 50"
az monitor app-insights query --app "appi-entrariskv35-dev-enkqnnv64liny" --analytics-query $query | ConvertFrom-Json
```

---

## Quick Test Workflow
```powershell
# 1. Deploy
Push-Location "/Users/thomas/git/GitHub/EntraAndAzureRisk/FunctionApp"
func azure functionapp publish $FUNC_APP --powershell
Pop-Location

# 2. Wipe (optional - for fresh test)
az storage blob delete-batch --source raw-data --account-name $STORAGE_ACCOUNT --auth-mode login

# 3. Run full sync
$FUNC_KEY = az functionapp function keys list -g $RG -n $FUNC_APP --function-name HttpTrigger --query "default" -o tsv
$uri = "https://${FUNC_APP}.azurewebsites.net/api/httptrigger?code=${FUNC_KEY}"
$body = @{ action = "start" } | ConvertTo-Json
$response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
$STATUS_URI = $response.statusQueryGetUri

# 4. Watch status
$startTime = Get-Date
while ($true) {
    Start-Sleep -Seconds 10
    $status = Invoke-RestMethod -Uri $STATUS_URI
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    Write-Host "${elapsed}s: $($status.runtimeStatus)"
    if ($status.runtimeStatus -in @('Completed', 'Failed')) { break }
}

# 5. Get results
$status.output.Indexing | ConvertTo-Json
```

---

## Expected Metrics (Current Baseline)

| Metric | Value |
|--------|-------|
| Full Sync Time | ~350-400 seconds |
| Delta Sync Time | ~220-250 seconds |
| Total Edges | ~830 |
| Total Principals | ~500 |
| Dashboard Size | ~6 MB |
| Longest Phase | SP Owners ~5s |


# Script
```powershell
<#
.SYNOPSIS
    DevOps utilities for deploying, testing, and monitoring the Alpenglow solution.

.DESCRIPTION
    Quick reference commands for Azure Function deployment, data management, and monitoring.
    All commands use Azure CLI (az) with PowerShell wrapping.

.EXAMPLE
    # Set variables first
    $FUNC_APP = "func-entrariskv35-data-dev-enkqnnv64liny"
    $STORAGE_ACCOUNT = "stentrariskv35devenkqnnv"
    $COSMOS_ACCOUNT = "cosno-entrariskv35-dev-enkqnnv64liny"
    $RG = "rg-entrarisk-v35-001"
    $DATABASE = "EntraData"
#>

# VARIABLES - Set these first

$FUNC_APP = "func-entrariskv35-data-dev-enkqnnv64liny"
$STORAGE_ACCOUNT = "stentrariskv35devenkqnnv"
$COSMOS_ACCOUNT = "cosno-entrariskv35-dev-enkqnnv64liny"
$RG = "rg-entrarisk-v35-001"
$DATABASE = "EntraData"

# 1. DEPLOY CHANGES TO AZURE

function Deploy-FunctionApp {
    [CmdletBinding()]
    param()
    
    Write-Verbose "Deploying Function App to Azure..."
    Push-Location "/Users/thomas/git/GitHub/EntraAndAzureRisk/FunctionApp"
    try {
        func azure functionapp publish $FUNC_APP --powershell
    }
    finally {
        Pop-Location
    }
}

# 2. WIPE TEST DATA (FRESH START)

function Clear-BlobStorage {
    [CmdletBinding()]
    param()
    
    Write-Warning "Deleting all blobs in raw-data container..."
    az storage blob delete-batch --source raw-data --account-name $STORAGE_ACCOUNT --auth-mode login
}

function Clear-CosmosDB {
    [CmdletBinding()]
    param()
    
    Write-Warning "Wiping Cosmos DB containers..."
    
    $containers = @('principals', 'resources', 'edges', 'policies', 'events', 'audit')
    
    # Delete containers
    foreach ($container in $containers) {
        Write-Verbose "Deleting container: $container"
        az cosmosdb sql container delete -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n $container --yes
    }
    
    # Recreate containers
    Write-Verbose "Recreating containers..."
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n principals --partition-key-path "/objectId" --throughput 400 -o none
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n resources --partition-key-path "/objectId" --throughput 400 -o none
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n edges --partition-key-path "/edgeType" --throughput 400 -o none
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n policies --partition-key-path "/objectId" --throughput 400 -o none
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n events --partition-key-path "/eventId" --throughput 400 -o none
    az cosmosdb sql container create -a $COSMOS_ACCOUNT -g $RG -d $DATABASE -n audit --partition-key-path "/auditDate" --throughput 400 -o none
}

function Clear-AllTestData {
    [CmdletBinding()]
    param()
    
    Clear-BlobStorage
    Clear-CosmosDB
}

# 3. RUN ORCHESTRATION

function Get-FunctionKey {
    [CmdletBinding()]
    param()
    
    Write-Verbose "Retrieving function key..."
    $key = az functionapp function keys list -g $RG -n $FUNC_APP --function-name HttpTrigger --query "default" -o tsv
    return $key
}

function Start-FullSync {
    [CmdletBinding()]
    param()
    
    $funcKey = Get-FunctionKey
    $uri = "https://${FUNC_APP}.azurewebsites.net/api/httptrigger?code=${funcKey}"
    
    Write-Verbose "Triggering full sync..."
    $body = @{ action = "start" } | ConvertTo-Json
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
    
    return $response
}

function Start-DeltaSync {
    [CmdletBinding()]
    param()
    
    $funcKey = Get-FunctionKey
    $uri = "https://${FUNC_APP}.azurewebsites.net/api/httptrigger?code=${funcKey}"
    
    Write-Verbose "Triggering delta sync..."
    $body = @{ 
        action = "start"
        useDelta = $true
    } | ConvertTo-Json
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
    
    return $response
}

function Get-OrchestrationStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatusUri
    )
    
    $status = Invoke-RestMethod -Uri $StatusUri
    return $status | Select-Object runtimeStatus, output
}

# 4. MONITOR PERFORMANCE

function Watch-OrchestrationStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatusUri
    )
    
    $startTime = Get-Date
    
    while ($true) {
        Start-Sleep -Seconds 10
        
        $status = Invoke-RestMethod -Uri $StatusUri
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        
        Write-Verbose "${elapsed}s: $($status.runtimeStatus)"
        
        if ($status.runtimeStatus -in @('Completed', 'Failed')) {
            break
        }
    }
    
    return $status
}

function Get-IndexingStatistics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatusUri
    )
    
    $status = Invoke-RestMethod -Uri $StatusUri
    
    if ($status.output.Indexing) {
        $status.output.Indexing.PSObject.Properties | ForEach-Object {
            $stats = $_.Value
            [PSCustomObject]@{
                Type = $_.Name
                Total = $stats.Total
                New = $stats.New
                Modified = $stats.Modified
                CosmosWrites = $stats.CosmosWrites
            }
        }
    }
}

function Get-PhaseTiming {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatusUri
    )
    
    $status = Invoke-RestMethod -Uri $StatusUri
    return $status.output.Collection.Edges.Summary.phaseTiming
}

# 5. CHECK BLOB STORAGE

function Get-RecentBlobs {
    [CmdletBinding()]
    param(
        [int]$Count = 20
    )
    
    $blobs = az storage blob list --container-name raw-data --account-name $STORAGE_ACCOUNT --auth-mode login --query "[].{name:name, size:properties.contentLength}" | ConvertFrom-Json
    return $blobs | Select-Object -First $Count
}

function Get-EdgeStatistics {
    [CmdletBinding()]
    param()
    
    Write-Verbose "Downloading latest edges file..."
    
    $latestFolder = (az storage blob list --container-name raw-data --account-name $STORAGE_ACCOUNT --auth-mode login --query "[0].name" -o tsv).Split('/')[0]
    $edgesFile = "$latestFolder/$latestFolder-edges.jsonl"
    
    az storage blob download --container-name raw-data --account-name $STORAGE_ACCOUNT --name $edgesFile --file "/tmp/edges.jsonl" --auth-mode login -o none
    
    $edges = Get-Content "/tmp/edges.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }
    
    Write-Verbose "Total edges: $($edges.Count)"
    
    $edgeTypes = $edges | Group-Object -Property edgeType | Sort-Object Count -Descending
    return $edgeTypes | Select-Object Name, Count
}

# 6. DASHBOARD VALIDATION

function Get-Dashboard {
    [CmdletBinding()]
    param(
        [string]$OutputPath = "/tmp/dashboard.html"
    )
    
    $dashKey = az functionapp function keys list -g $RG -n $FUNC_APP --function-name Dashboard --query "default" -o tsv
    $uri = "https://${FUNC_APP}.azurewebsites.net/api/dashboard?code=${dashKey}"
    
    Invoke-WebRequest -Uri $uri -OutFile $OutputPath
    
    $fileInfo = Get-Item $OutputPath
    Write-Verbose "Dashboard saved to $OutputPath ($('{0:N2}' -f ($fileInfo.Length / 1MB)) MB)"
    
    return $fileInfo
}

function Get-DashboardMetrics {
    [CmdletBinding()]
    param(
        [string]$DashboardPath = "/tmp/dashboard.html"
    )
    
    if (-not (Test-Path $DashboardPath)) {
        Write-Warning "Dashboard file not found at $DashboardPath"
        return
    }
    
    $content = Get-Content $DashboardPath -Raw
    
    if ($content -match 'Changes:.*?del') {
        return $Matches[0]
    }
}

# 7. MAKE TEST CHANGES

function Invoke-TestChanges {
    [CmdletBinding()]
    param()
    
    Write-Verbose "Invoking test data changes..."
    & pwsh -NoProfile -File "/Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Invoke-AlpenglowTestData.ps1" -NonInteractive -Action Changes
}

# 8. VIEW APPLICATION INSIGHTS LOGS

function Get-RecentLogs {
    [CmdletBinding()]
    param(
        [int]$Minutes = 15,
        [int]$Take = 50
    )
    
    $query = "traces | where timestamp > ago($($Minutes)m) | order by timestamp desc | take $Take"
    
    az monitor app-insights query --app "appi-entrariskv35-dev-enkqnnv64liny" --analytics-query $query | ConvertFrom-Json
}

# QUICK TEST WORKFLOW

function Start-QuickTest {
    [CmdletBinding()]
    param(
        [switch]$WipeData,
        [switch]$SkipDeploy
    )
    
    # 1. Deploy
    if (-not $SkipDeploy) {
        Write-Verbose "Step 1: Deploying..."
        Deploy-FunctionApp
    }
    
    # 2. Wipe (optional)
    if ($WipeData) {
        Write-Verbose "Step 2: Wiping test data..."
        Clear-BlobStorage
    }
    
    # 3. Run full sync
    Write-Verbose "Step 3: Starting full sync..."
    $response = Start-FullSync
    $statusUri = $response.statusQueryGetUri
    
    # 4. Watch status
    Write-Verbose "Step 4: Monitoring orchestration..."
    $result = Watch-OrchestrationStatus -StatusUri $statusUri
    
    # 5. Get results
    Write-Verbose "Step 5: Retrieving results..."
    Get-IndexingStatistics -StatusUri $statusUri
    
    return $result
}


# EXPECTED METRICS (CURRENT BASELINE)

<#
Expected Metrics:
- Full Sync Time: ~350-400 seconds
- Delta Sync Time: ~220-250 seconds
- Total Edges: ~830
- Total Principals: ~500
- Dashboard Size: ~6 MB
- Longest Phase: SP Owners ~5s
#>
```