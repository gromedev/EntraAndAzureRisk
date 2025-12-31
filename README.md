# Entra Risk Analysis - Azure Functions Data Collection

Azure Functions application for collecting Microsoft Entra ID user data with delta change detection.

## Architecture

```
Microsoft Graph API 
    → CollectEntraUsers Activity 
    → Blob Storage (JSONL format)
    → IndexInCosmosDB Activity
    → Cosmos DB (3 containers: users_raw, user_changes, snapshots)
```

---

## Project Structure

```
/
├── FunctionApp/
│   ├── Activities/
│   │   ├── CollectEntraUsers/          # Queries Graph API, writes to blob
│   │   │   ├── run.ps1
│   │   │   └── function.json
│   │   ├── IndexInCosmosDB/            # Reads blob, writes to Cosmos with delta detection
│   │   │   ├── run.ps1
│   │   │   └── function.json
│   │   └── TestAIFoundry/              # Optional AI Foundry connectivity test
│   │       ├── run.ps1
│   │       └── function.json
│   ├── Orchestrators/
│   │   └── EntraDataOrchestrator/      # Coordinates the 3 activities
│   │       ├── run.ps1
│   │       └── function.json
│   ├── HttpStart/                      # HTTP trigger for manual execution
│   │   ├── run.ps1
│   │   └── function.json
│   ├── TimerTrigger/                   # Scheduled trigger (every 6 hours)
│   │   ├── run.ps1
│   │   └── function.json
│   ├── Modules/
│   │   ├── EntraDataCollection.psd1    # Module manifest
│   │   └── EntraDataCollection.psm1    # Module implementation
│   ├── host.json                       # Function app configuration
│   ├── profile.ps1                     # Startup script
│   └── requirements.psd1               # PowerShell dependencies
└── Infrastructure/
    ├── main-pilot-delta.bicep          # Azure resource definitions
    └── deploy-pilot-delta.ps1          # Deployment script
```

---

## Function App Components

### Activities

#### CollectEntraUsers

**Purpose:** Queries Microsoft Graph API and streams user data to blob storage.

**Implementation:** `Activities/CollectEntraUsers/run.ps1`

**Key Features:**
- **Token caching** with 55-minute expiry to reduce IMDS calls
- **Sequential processing** of users (not parallel)
- **Streaming to blob** using 1MB StringBuilder buffer
- **Periodic flush** every ~5000 users with retry logic (3 attempts, exponential backoff)
- **Single timestamp capture** to prevent race conditions
- **Retry logic** on blob write failures to prevent data loss

**Process Flow:**
1. Acquires cached Graph API and Storage tokens
2. Initializes append blob in storage account
3. Queries Graph API with pagination (999 users per batch)
4. Transforms each user to JSONL format
5. Appends to blob periodically (every 5000 users)
6. Performs final flush at completion
7. Returns summary with user counts and blob path

path

**Environment Variables:**
- `STORAGE_ACCOUNT_NAME`
- `COSMOS_DB_ENDPOINT`
- `COSMOS_DB_DATABASE`
- `TENANT_ID`
- `BATCH_SIZE` (optional, default: 999)

**Output:**
```json
{
  "Success": true,
  "UserCount": 250000,
  "BlobName": "2025-12-30T14-30-00Z/2025-12-30T14-30-00Z-users.jsonl",
  "Timestamp": "2025-12-30T14-30-00Z",
  "Summary": {
    "enabledCount": 240000,
    "disabledCount": 10000,
    "memberCount": 245000,
    "guestCount": 5000
  }
}
```

---

#### IndexInCosmosDB

**Purpose:** Reads blob data, performs delta detection, and writes only changed users to Cosmos DB.

**Implementation:** `Activities/IndexInCosmosDB/run.ps1`

**Key Features:**
- **Callback pattern** for Cosmos queries (processes pages immediately without accumulating in memory)
- **Parallel Cosmos writes** using ForEach-Object -Parallel with 10 threads
- **Delta detection** compares current vs existing users to identify new, modified, deleted, and unchanged users
- **Smart error handling** distinguishes 404 (first run, no data) from real Cosmos failures
- **Returns structured error** instead of throwing to preserve orchestrator's partial success pattern
- **Change logging** writes all changes to user_changes container
- **Snapshot metadata** writes collection summary to snapshots container

**Process Flow:**
1. Reads JSONL data from blob storage
2. Parses into hashtable for fast lookup
3. Queries existing users from Cosmos using callback pattern
4. Performs delta comparison:
   - New users (not in existing data)
   - Modified users (accountEnabled, userType, or lastSignInDateTime changed)
   - Deleted users (in existing but not in current)
   - Unchanged users
5. Writes changes using parallel batch execution
6. Logs all changes to user_changes container
7. Writes summary to snapshots container

**Environment Variables:**
- `COSMOS_DB_ENDPOINT`
- `COSMOS_DB_DATABASE`
- `COSMOS_CONTAINER_USERS_RAW`
- `COSMOS_CONTAINER_USER_CHANGES`
- `COSMOS_CONTAINER_SNAPSHOTS`
- `STORAGE_ACCOUNT_NAME`
- `ENABLE_DELTA_DETECTION` (default: true)

**Output:**
```json
{
  "Success": true,
  "TotalUsers": 250000,
  "NewUsers": 1200,
  "ModifiedUsers": 200,
  "DeletedUsers": 50,
  "UnchangedUsers": 248550,
  "CosmosWriteCount": 1450,
  "SnapshotId": "2025-12-30T14-30-00Z"
}
```

**Delta Detection Example:**
- Total users: 250,000
- First run: Writes all 250,000 (no existing data)
- Subsequent run: ~1,400 changed (0.56% of users)
- Write reduction: 99.44%

---

#### TestAIFoundry

**Purpose:** Optional connectivity test for AI Foundry integration.

**Implementation:** `Activities/TestAIFoundry/run.ps1`

**Key Features:**
- **Graceful failure pattern** - always returns Success: true, never blocks orchestration
- Verifies AI Foundry endpoint is configured
- Acquires AI Foundry token using managed identity
- Auto-detects model deployment if not specified
- Sends test prompt referencing collected data
- Returns warning messages if configuration incomplete

**Failure Modes (all non-blocking):**
- Missing endpoint → Skip with message
- Token fails → Skip with message
- No models deployed → Skip with instructions
- API call fails → Log warning, continue

**Environment Variables (all optional):**
- `AI_FOUNDRY_ENDPOINT`
- `AI_FOUNDRY_PROJECT_NAME`
- `AI_MODEL_DEPLOYMENT_NAME`

---

### Orchestrator

#### EntraDataOrchestrator

**Purpose:** Coordinates the data collection workflow with intelligent retry logic.

**Implementation:** `Orchestrators/EntraDataOrchestrator/run.ps1`

**Workflow:**
1. **CollectEntraUsers** - Fails → STOP entire orchestration (critical, no data collected)
2. **IndexInCosmosDB** - Fails → RETRY up to 3 times with 60-second delays (data is safe in blob)
3. **TestAIFoundry** - Fails → CONTINUE (optional feature, not critical)

**Key Features:**
- **Single timestamp capture** prevents race conditions between blob path and Cosmos document IDs
- **Intelligent retry** for IndexInCosmosDB preserves blob for manual recovery
- **Comprehensive result** includes efficiency metrics showing write reduction

**Output:**
```json
{
  "OrchestrationId": "abc123",
  "Status": "Completed",
  "Timestamp": "2025-12-30T14:30:00Z",
  "Collection": {
    "Success": true,
    "UserCount": 250000,
    "BlobPath": "2025-12-30T14-30-00Z/users.jsonl"
  },
  "Indexing": {
    "Success": true,
    "TotalUsers": 250000,
    "Changes": {
      "New": 1200,
      "Modified": 200,
      "Deleted": 50,
      "Unchanged": 248550
    },
    "CosmosWrites": 1450,
    "CosmosWriteReduction": 99.42
  },
  "Summary": {
    "WriteEfficiency": "1450 writes instead of 250000 (99.42% reduction)"
  }
}
```

---

### Triggers

#### HttpStart

**Purpose:** HTTP endpoint for manually triggering the orchestrator.

**Implementation:** `HttpStart/run.ps1`

**Binding:** POST method, function-level authentication

**Usage:**
```bash
curl -X POST https://<function-app-name>.azurewebsites.net/api/HttpStart?code=<function-key>
```

**Response:** Returns Durable Functions status URLs for monitoring.

---

#### TimerTrigger

**Purpose:** Automatically triggers the orchestrator on a schedule.

**Implementation:** `TimerTrigger/run.ps1`

**Schedule:** `0 0 */6 * * *` (every 6 hours)

**CRON Format:** `"second minute hour day month dayOfWeek"`

**Schedule Examples:**
```
0 0 */6 * * *        - Every 6 hours (default)
0 0 */4 * * *        - Every 4 hours
0 0 0,6,12,18 * * *  - At midnight, 6am, noon, 6pm
0 0 2 * * *          - Daily at 2:00 AM UTC
```

Modify `function.json` to change the schedule.

---

## PowerShell Module

### EntraDataCollection

**Version:** 1.2.0

**Manifest:** `Modules/EntraDataCollection.psd1`  
**Implementation:** `Modules/EntraDataCollection.psm1`

**Exported Functions:**

#### Token Management

**`Get-ManagedIdentityToken`**
- Acquires token using Azure Managed Identity via IMDS endpoint
- Works with: Graph API, Storage, Cosmos DB, Key Vault, AI Foundry
- No credentials stored - runtime token acquisition

**`Get-CachedManagedIdentityToken`**
- Token caching with 55-minute expiry (5-minute safety buffer)
- Module-level cache: `$script:TokenCache`
- Reduces IMDS calls by ~95%
- Automatically refreshes expired tokens

#### Graph API
**`Invoke-GraphWithRetry`**
- Executes Graph API calls with exponential backoff retry
- Retry logic:
  - 5xx server errors: 5s, 10s, 20s delays
  - 429 rate limiting: Uses Retry-After header, doesn't count against retry budget
  - 408 timeout: Retries with backoff
- Default: 3 retry attempts

#### Memory Management

**`Test-MemoryPressure`**
- Monitors process memory usage
- Triggers garbage collection if threshold exceeded
- Default thresholds: 12GB critical, 10GB warning
- Note: Currently not used in activities

#### Blob Storage

**`Initialize-AppendBlob`**
- Creates append blob or verifies it already exists
- Required before using Add-BlobContent
- Handles 409 conflict (blob already exists)

**`Add-BlobContent`**
- Appends content to append blob with retry logic
- Parameters: MaxRetries (default: 3), BaseRetryDelaySeconds (default: 2)
- Retries on: 5xx errors, 408 timeout, 429 throttle
- Exponential backoff: 2s, 4s, 8s
- Throws after exhausting retries to prevent silent data loss

#### Cosmos DB

**`Write-CosmosDocument`**
- Writes single document to Cosmos DB
- Uses REST API with bearer token authentication
- Partition key must be document.id

**`Write-CosmosBatch`**
- Writes documents sequentially in batches
- Default batch size: 100 documents
- Progress logging every 500 documents

**`Write-CosmosParallelBatch`**
- **Parallel batch writes** using ForEach-Object -Parallel
- Default: 10 parallel threads (configurable via ParallelThrottle parameter)
- Built-in retry logic per document (3 attempts, exponential backoff)
- Retries on: 429 (throttle), 5xx (server errors)
- Significantly faster than sequential writes for large datasets

**`Get-CosmosDocuments`**
- Queries Cosmos DB with **callback pattern**
- ProcessPage parameter: scriptblock called for each page of results
- Processes pages immediately without accumulating into array
- Reduces memory usage by eliminating intermediate array storage
- Handles pagination automatically with continuation tokens

**Callback Pattern Example:**
```powershell
$existingUsers = @{}
Get-CosmosDocuments `
    -Endpoint $cosmosEndpoint `
    -Database $cosmosDatabase `
    -Container $containerUsersRaw `
    -Query $query `
    -AccessToken $cosmosToken `
    -ProcessPage {
        param($Documents)
        foreach ($doc in $Documents) {
            $existingUsers[$doc.objectId] = $doc
        }
    }
```

---

## Configuration Files

### host.json

**Purpose:** Azure Functions host-level configuration

**Key Settings:**
```json
{
  "version": "2.0",
  "functionTimeout": "00:10:00",
  "extensions": {
    "durableTask": {
      "hubName": "EntraRiskHub"
    }
  }
}
```

**Function Timeout:** 90 minutes
- Allows sufficient time for first-run data collection
- Can be reduced after first successful run if desired

---

### profile.ps1

**Purpose:** Function App startup script (runs once when app starts)

**Functionality:**
- Detects managed identity: `$env:MSI_SECRET`
- Disables Azure context autosave
- Connects to Azure using managed identity: `Connect-AzAccount -Identity`
- Sets Azure context to current subscription

---

### requirements.psd1

**Purpose:** PowerShell module dependencies from PSGallery

**Dependencies:**
```powershell
@{
    'Az.Accounts' = '2.*'
    'Az.Storage' = '6.*'
    'Az.KeyVault' = '5.*'
}
```

---

## Infrastructure

### main-pilot-delta.bicep

**Purpose:** Infrastructure as Code for complete Azure resource deployment

**Parameters:**
- `workloadName` - Resource naming prefix (default: "entrarisk")
- `environment` - dev/test/prod
- `location` - Azure region
- `tenantId` - Entra ID tenant ID (required)
- `blobRetentionDays` - Blob lifecycle retention (default: 7)

**Deployed Resources:**

#### Storage Account
- SKU: Standard_LRS (locally redundant storage)
- Access tier: Hot
- TLS: 1.2 minimum
- Public access: Disabled
- Containers:
  - `raw-data` - JSONL exports from Graph API
  - `analysis` - Analysis outputs
- **Lifecycle policy:** Auto-deletes blobs after retention period

#### Cosmos DB Account
- Type: Serverless (no provisioned throughput)
- Consistency: Session level
- Free tier: Enabled
- Backup: Continuous (7-day point-in-time restore)

**Database:** EntraData

**Container: users_raw**
- Purpose: Current state of all users
- Partition key: `/objectId`
- Indexed fields: objectId, userPrincipalName, accountEnabled, userType, lastSignInDateTime, collectionTimestamp, lastModified
- TTL: Disabled (permanent)
- Unique key: objectId

**Container: user_changes**
- Purpose: Audit trail of all changes
- Partition key: `/snapshotId`
- Indexed fields: objectId, changeType, changeTimestamp, snapshotId
- TTL: 31536000 seconds (365 days)

**Container: snapshots**
- Purpose: Collection metadata and summaries
- Partition key: `/id`
- TTL: Disabled (permanent)

#### Function App
- Plan: Consumption (Dynamic, Y1 SKU)
- Runtime: PowerShell 7.4
- Identity: System-assigned managed identity
- HTTPS: Enforced
- All environment variables pre-configured

#### Application Insights
- Type: Web application
- Workspace: Connected to Log Analytics
- Retention: 30 days
- Purpose: Monitoring, logging, performance metrics

#### Key Vault
- SKU: Standard
- Soft delete: Enabled (7 days)
- Access: RBAC only
- Purpose: Secret storage (reserved for future use)

#### AI Foundry
- Hub: Basic tier
- Project: Basic tier
- Purpose: Optional AI/ML integration

#### RBAC Assignments
- Function App → Storage Blob Data Contributor
- Function App → Cosmos DB Built-in Data Contributor
- Function App → Key Vault Secrets User
- AI Foundry Hub → Storage Blob Data Contributor
- AI Foundry Hub → Cosmos DB Data Reader

**Outputs:**
All resource names, endpoints, principal IDs for verification

---

### deploy-pilot-delta.ps1

**Purpose:** Automated deployment script with validation

**Prerequisites:**
- Azure PowerShell modules: Az.Accounts, Az.Resources
- Contributor access to Azure subscription
- Entra ID tenant ID

**Usage:**
```powershell
.\deploy-pilot-delta.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>" `
    -ResourceGroupName "rg-entrarisk-pilot-001" `
    -Location "eastus" `
    -Environment "dev" `
    -BlobRetentionDays 7
```

**Parameters:**
- `SubscriptionId` - Required
- `TenantId` - Required
- `ResourceGroupName` - Default: rg-entrarisk-pilot-001
- `Location` - Default: eastus
- `Environment` - Default: dev (dev/test/prod)
- `BlobRetentionDays` - Default: 7 (1-365)
- `WorkloadName` - Default: entrarisk

**Deployment Process:**
1. Connects to Azure (prompts if not authenticated)
2. Creates or verifies resource group with tags
3. Deploys Bicep template (5-10 minutes)
4. Displays all deployed resources
5. Shows required manual actions
6. Saves deployment info to JSON file

**Manual Steps After Deployment:**

1. **Grant Graph API Permissions (CRITICAL)**
   - Azure Portal → Entra ID → Enterprise Applications
   - Search for function app name
   - API Permissions → Add permission → Microsoft Graph → Application permissions
   - Select: User.Read.All
   - Grant admin consent for tenant

2. **Deploy Function App Code**
   - Push code to Azure DevOps or deploy manually:
   ```bash
   cd FunctionApp
   func azure functionapp publish <function-app-name>
   ```

3. **Deploy AI Model (Optional)**
   - Visit https://ai.azure.com
   - Deploy gpt-4o-mini model in project

4. **Test Deployment**
   - Trigger via HTTP endpoint or wait for timer
   - Monitor in Application Insights
   - Verify blob and Cosmos data

**Output:**
- Console output with resource details
- JSON file: `deployment-info-delta-<timestamp>.json`
- Cost estimates displayed

---

## Data Models

### Cosmos DB: users_raw

```json
{
  "id": "00000000-0000-0000-0000-000000000000",
  "objectId": "00000000-0000-0000-0000-000000000000",
  "userPrincipalName": "user@domain.com",
  "accountEnabled": true,
  "userType": "Member",
  "createdDateTime": "2023-01-15T10:30:00Z",
  "lastSignInDateTime": "2025-12-29T14:25:00Z",
  "collectionTimestamp": "2025-12-30T14:30:00Z",
  "lastModified": "2025-12-30T14:35:00Z",
  "snapshotId": "2025-12-30T14-30-00Z"
}
```

### Cosmos DB: user_changes

```json
{
  "id": "guid",
  "objectId": "00000000-0000-0000-0000-000000000000",
  "changeType": "modified",
  "changeTimestamp": "2025-12-30T14:35:00Z",
  "snapshotId": "2025-12-30T14-30-00Z",
  "previousValue": {
    "accountEnabled": true,
    "userType": "Member"
  },
  "newValue": {
    "accountEnabled": false,
    "userType": "Member"
  },
  "delta": {
    "accountEnabled": {
      "old": true,
      "new": false
    }
  }
}
```

**Change Types:**
- `new` - User did not exist in previous collection
- `modified` - One or more user attributes changed
- `deleted` - User no longer exists in current collection

### Cosmos DB: snapshots

```json
{
  "id": "2025-12-30T14-30-00Z",
  "snapshotId": "2025-12-30T14-30-00Z",
  "collectionTimestamp": "2025-12-30T14:35:00Z",
  "collectionType": "users",
  "totalUsers": 250000,
  "newUsers": 1200,
  "modifiedUsers": 200,
  "deletedUsers": 50,
  "unchangedUsers": 248550,
  "cosmosWriteCount": 1450,
  "blobPath": "2025-12-30T14-30-00Z/2025-12-30T14-30-00Z-users.jsonl",
  "deltaDetectionEnabled": true
}
```

### Blob Storage: raw-data

**Format:** JSONL (JSON Lines - one JSON object per line)

**Path Structure:** `<timestamp>/<timestamp>-users.jsonl`

**Example Path:** `2025-12-30T14-30-00Z/2025-12-30T14-30-00Z-users.jsonl`

**Sample Content:**
```jsonl
{"objectId":"00000000-0000-0000-0000-000000000001","userPrincipalName":"user1@domain.com","accountEnabled":true,"userType":"Member","createdDateTime":"2023-01-15T10:30:00Z","lastSignInDateTime":"2025-12-29T14:25:00Z","collectionTimestamp":"2025-12-30T14:30:00Z"}
{"objectId":"00000000-0000-0000-0000-000000000002","userPrincipalName":"user2@domain.com","accountEnabled":false,"userType":"Guest","createdDateTime":"2024-06-20T08:15:00Z","lastSignInDateTime":null,"collectionTimestamp":"2025-12-30T14:30:00Z"}
```

**Lifecycle:** Auto-deleted after retention period (default: 7 days)

---

## Deployment Guide

### Step 1: Clone Repository

```bash
git clone https://github.com/gromedev/EntraAndAzureRisk.git
cd EntraAndAzureRisk
```

### Step 2: Install Prerequisites

```powershell
# Install Azure PowerShell modules
Install-Module -Name Az.Accounts, Az.Resources -Scope CurrentUser
```

### Step 3: Deploy Infrastructure

```powershell
cd Infrastructure
.\deploy-pilot-delta.ps1 `
    -SubscriptionId "<your-subscription-id>" `
    -TenantId "<your-tenant-id>"
```

Wait 5-10 minutes for deployment to complete.

***Error: 8.25 PM***
VERBOSE: Performing the operation "Creating Deployment" on target "rg-entrarisk-pilot-001".
Write-Error: Deployment failed: 20.24.13 - Error: Code=InvalidTemplateDeployment; Message=The template deployment 'delta-pilot-20251230-202335' is not valid according to the validation procedure. The tracking id is 'c65f4b4c-b216-4b31-9148-b280ed653c1b'. See inner errors for details.

*** Missing Resource Provider Registration
Because you are using AI Foundry (Machine Learning Services) and Cosmos DB, your subscription must have those providers registered. If they aren't, the template is considered "Invalid."
Run these commands to ensure your subscription is ready:

```powershell
az login
az provider register --namespace Microsoft.MachineLearningServices
az provider register --namespace Microsoft.DocumentDB
az provider register --namespace Microsoft.Insights
```

***Cosmos DB***
az cosmosdb list --query "[?enableFreeTier=='true'].{Name:name, ResourceGroup:resourceGroup}"

WTF???? Severless isnt supported on the free tier??? This breaks the entire solution????
    You have to remove "EnableServerless" because Azure views Free Tier and Serverless as two completely different ways of "renting" the database. They are fundamentally incompatible.
    Think of it like choosing a pricing plan for a gym:
    Provisioned Throughput (Standard): You pay a monthly membership fee to have access to the equipment whenever you want.
    Free Tier: This is a "First-month free" coupon for that Standard membership.
    Serverless: You don't have a membership; you just pay $5 every time you walk through the door.
    Azure does not allow you to apply a "membership coupon" (Free Tier) to a "pay-as-you-go" (Serverless) plan.


***The Potential Conflict: ***Storage Keys vs. RBAC
In your functionApp resource, you are using the Storage Account Access Key to build the connection string:

value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}...'

The Risk: If your organization has a policy that "Disables Storage Account Key Access" (which is common for security), storageAccount.listKeys() will fail during deployment.

The Fix: Since you already gave the Function App the Storage Blob Data Contributor role, you can change your Function App to use Identity-based connections. This is cleaner and doesn't require keys.


### Step 4: Grant Graph API Permissions

**This step is CRITICAL - the function will fail without it**

1. Open Azure Portal: https://portal.azure.com
2. Navigate to Entra ID → Enterprise Applications
3. Search for your function app name (shown in deployment output)
4. Select the application
5. Go to API Permissions
6. Click "Add a permission"
7. Select "Microsoft Graph"
8. Select "Application permissions"
9. Search for and select: `User.Read.All`
10. Click "Add permissions"
11. Click "Grant admin consent for [your tenant]"
12. Confirm by clicking "Yes"

Wait 2-3 minutes for permissions to propagate.

### Step 5: Deploy Function App Code

```bash
cd FunctionApp
func azure functionapp publish <your-function-app-name>
```

### Step 6: Verify Deployment

**Trigger a test run:**
```bash
curl -X POST "https://<function-app-name>.azurewebsites.net/api/HttpStart?code=<function-key>"
```

**Monitor execution:**
- Azure Portal → Function App → Application Insights → Live Metrics
- Watch for completion (should complete within timeout period)

**Verify data:**
- Blob Storage → raw-data container → Should contain timestamped JSONL file
- Cosmos DB → users_raw container → Should contain user documents
- Cosmos DB → snapshots container → Should contain 1 summary document

---

## Monitoring

### Application Insights Queries

**Function Duration:**
```kusto
requests
| where name == "EntraDataOrchestrator"
| summarize avg(duration), max(duration), min(duration) by bin(timestamp, 1h)
| render timechart
```

**Error Rate:**
```kusto
exceptions
| where timestamp > ago(24h)
| summarize count() by operation_Name, outerMessage
| order by count_ desc
```

**Delta Efficiency:**
```kusto
traces
| where message contains "CosmosWriteReduction"
| project timestamp, message
| order by timestamp desc
```

**Memory Usage:**
```kusto
performanceCounters
| where name == "Private Bytes"
| where timestamp > ago(24h)
| summarize avg(value/1024/1024), max(value/1024/1024) by bin(timestamp, 5m)
| render timechart
```

### Key Metrics

Monitor these values to ensure healthy operation:

- **Function timeout** - Should complete within 90 minutes
- **Delta write reduction** - Should be ~99% after first run
- **Blob storage growth** - Should stay under 2GB with 7-day retention
- **Cosmos RU consumption** - Track request units used per run
- **Error rate** - Should be minimal (<0.1%)

---

## Troubleshooting

### Write-Error: Deployment failed: 21.58.38 - Error: Code=InvalidTemplateDeployment; Message=The template deployment 'delta-pilot-20251230-215832' is not valid according to the validation procedure. The tracking id is 'dfac410c-e2f8-452a-a3f4-65c978628480'. See inner errors for details.
- Write-Error: Deployment failed: 21.58.38 - Error: Code=InvalidTemplateDeployment; Message=The template deployment 'delta-pilot-20251230-215832' is not valid according to the validation procedure. The tracking id is 'dfac410c-e2f8-452a-a3f4-65c978628480'. See inner errors for details.
- The issue: Key Vault soft delete. When you deleted the resource group, the Key Vault entered a soft-deleted state (7-day retention). The new deployment uses the same name (generated from resource group ID via uniqueString()), causing validation to fail.
- Verify: az keyvault list-deleted --query "[].{Name:name, Location:location, DeletionDate:properties.deletionDate}"
- Fix: az keyvault purge --name kventrariskdevhnaffeukql --location eastus

### Resource group
- az group delete --name rg-entra-risk-analysis --yes --no-wait  

### See inner errors / deployment errors
- az deployment group show --resource-group rg-entrarisk-pilot-001 --name delta-pilot-20251230-223727 --query properties.error --output json
- most likely it is not a template bug. It is a hard subscription quota block. So try a different region since quota is per region.

### Status Message: A vault with the same name already exists in deleted state.
- Key Vault names are globally unique. When you deleted the resource group, the Key Vault entered soft-deleted state. The name is still reserved at the platform level. ARM refuses to recreate it.
- Go to KeyVault -> Manage Soft deletes -> Purge. Or;

```
az keyvault purge \ --name <vault-name> \
```

### Status Message: The specified role definition with ID 
- az role assignment list --all -o table

Delete the conflicting Azure AI Developer role assignment

```
az role assignment delete --assignee e74a483a-24eb-455e-94b2-e12e560ffa84 --role "Azure AI Developer" --scope /subscriptions/4e5adb24-09e8-4a01-adbb-c6cee339f639/resourcegroups/rg-entrarisk-pilot-001/providers/Microsoft.MachineLearningServices/workspaces/hub-entrarisk-dev-36jut3xd6y2so

az role assignment delete --assignee 033e5f71-6a53-444b-aecb-4c31395e2716 --role "Storage Blob Data Contributor" --scope /subscriptions/4e5adb24-09e8-4a01-adbb-c6cee339f639/resourceGroups/rg-entrarisk-pilot-001/providers/Microsoft.Storage/storageAccounts/stentrariskdev36jut3xd6y
```

### Status Message: Database account creation failed.
- You requested a zone-redundant Cosmos DB account West Europe is capacity constrained This is not a quota issue and not transient retry noise ARM execution reached Cosmos control plane and was refused The deployment cannot succeed as written in that region.
- Option A: Disable zone redundancy (recommended for dev)
```bicep
properties: {
  enableAutomaticFailover: false
  locations: [
    {
      locationName: location
      failoverPriority: 0
      isZoneRedundant: false
    }
  ]
}
```
- Option B: Choose another region


### Function App Deployment Issues
- If URL shows "Function host is not running" error means the Function App is failing to start
- Streaming logs: func azure functionapp logstream func-entrarisk-data-dev-36jut3xd6y2so
- Reploy: ./FunctionApp/ func azure functionapp publish func-entrarisk-data-dev-36jut3xd6y2so --powershell --no-build
- Verification: curl -X POST "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger" -v
  - Trigger new orchestration: curl -X POST "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger?code=YOUR_FUNCTION_KEY"
  - Get Function Key: az functionapp keys list --name func-entrarisk-data-dev-36jut3xd6y2so --resource-group rg-entrarisk-pilot-001 --query "functionKeys.default" -o tsv
  - curl -X POST "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger?code=FUNCTION_KEY"


- Trigger new orchestration: curl -X POST "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger?code=FUNCTION_KEY"



### "Failed to acquire tokens"
- Verify managed identity is enabled on Function App
- Verify Graph API permissions granted with admin consent
- Check RBAC roles assigned to managed identity

### "Failed to initialize blob"
- Verify storage account name in app settings
- Verify managed identity has "Storage Blob Data Contributor" role on storage account

### "Failed to read Cosmos DB"
- Verify Cosmos endpoint in app settings
- Verify managed identity has "Cosmos DB Built-in Data Contributor" role
- Verify containers exist: users_raw, user_changes, snapshots

### Function times out
- First run may take up to 90 minutes
- Verify `functionTimeout` is set to "01:30:00" in host.json
- Check Application Insights for specific errors

### "Blob write failed after retries"
- Indicates network issue or storage throttling
- Function correctly throws to prevent data loss
- Check storage account metrics in Azure Portal
- Retry the orchestration

### Delta detection not working
- Verify `ENABLE_DELTA_DETECTION` is set to "true"
- Verify users_raw container has existing data
- Check for errors during Cosmos read operation
- Review IndexInCosmosDB output for error details

---

## Security

### Authentication
- **Managed Identity** - System-assigned identity for all Azure resources
- **No secrets stored** - All tokens acquired at runtime via IMDS endpoint
- **Token caching** - 55-minute cache reduces authentication calls

### Authorization (RBAC)
**Function App Managed Identity:**
- Storage Blob Data Contributor (storage account)
- Cosmos DB Built-in Data Contributor (Cosmos account)
- Key Vault Secrets User (Key Vault)
- Directory.Read.All (Microsoft Graph - requires admin consent)

**AI Foundry Hub Managed Identity:**
- Storage Blob Data Contributor (storage account)
- Cosmos DB Data Reader (Cosmos account)

### Network Security
- Storage: Public access disabled
- Cosmos DB: Firewall with RBAC
- Function App: HTTPS enforced
- Key Vault: Soft delete enabled

### Data Protection
- Encryption at rest: Microsoft-managed keys
- Encryption in transit: TLS 1.2 minimum
- Backup: Cosmos continuous backup (7-day PITR)
- Retention: Configurable blob lifecycle (default 7 days)

---

## Maintenance

### Regular Tasks

**Weekly:**
- Review Application Insights for errors
- Monitor function execution duration
- Verify delta detection efficiency

**Monthly:**
- Review Cosmos DB RU consumption
- Check blob storage capacity
- Verify lifecycle policy deleting old blobs
- Review change logs for anomalies

**Quarterly:**
- Update PowerShell modules if needed
- Review RBAC assignments
- Check for new Graph API fields to collect

### Updates

**Module Updates:**
1. Modify `EntraDataCollection.psm1`
2. Increment version in `EntraDataCollection.psd1`
3. Redeploy function app

**Infrastructure Updates:**
1. Modify `main-pilot-delta.bicep`
2. Run `deploy-pilot-delta.ps1`

---

## Support Resources

- **Azure Functions Documentation:** https://docs.microsoft.com/azure/azure-functions/
- **Microsoft Graph API:** https://docs.microsoft.com/graph/
- **Cosmos DB Documentation:** https://docs.microsoft.com/azure/cosmos-db/
- **PowerShell 7.4:** https://docs.microsoft.com/powershell/

**Portals:**
- Azure Portal: https://portal.azure.com
- Entra Admin Center: https://entra.microsoft.com
- AI Foundry: https://ai.azure.com

**GitHub Repository:** https://github.com/gromedev/EntraAndAzureRisk

---
