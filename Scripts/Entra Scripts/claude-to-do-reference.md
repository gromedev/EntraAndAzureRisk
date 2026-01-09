1)
A big part of this solution is testing for delta changes and making historical trends. 
I have two issues:
1.a) - Is Audit (200) actually showing anything other than "new"? 
	 - Sorting by "changeType" only has "new"
	 - I know for a fact that there are modified and deleted objects. I have used the Invoke-AlpenglowTestData which includes making random changes.

1.b) Even when 3.a has been addressed - assuming everything works, it still seems difficult to be able to actually use it for anything. Other than the audit tab, we dont really have any indications of what has changed and when. 

***In order to test changes, you can run this script: /Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Invoke-AlpenglowTestData.ps1***
***the /Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Invoke-AlpenglowTestData.ps1 script generates random data that should generate modified, deleted, etc events***


2)
2.a) Dashboard > Principals > Groups

For groupTypes: are the null values because they are assigned? If that is the case, can we show that they are assigned?

"Fix Groups table - show 'Assigned' for null groupTypes, reorder memberCount columns"

ONLY if it is assigned. It shouldnt show "assigned" if -eq null

"I understand - for Groups with null groupTypes, we should show "Assigned" (since Microsoft 365 groups have ["Unified"] and Dynamic groups have ["DynamicMembership"], but Assigned/Security groups have null). Let me check the current data and fix both the collector and the dashboard."

NO, ASSIGNED SHOULDNT JUST REPLACE NULL. WE NEED THE FUCKING VALUE


this might require changing the collector and index scripts so that it is shown in the blobs and therefore cosmos db

2.b) 
Dashboard > Principals > Groups

I want the membercounts (direct, transitive/indirect) to be ordered so they are next to each other



3) 
Dashboard > Policies > App Protection
It's showing No app protection policies found (0 of 272 in container)
But I KNOW theres at least two app protection policies:
- Alpenglow-Test-AppProtection-2c5f6427
- Test - App Protection

And I have confirmed that both are deployed


4) 

I had asked you to look at: /Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Entra Scripts

You concluded that the following improvements could be made:

Aspect	Entra Scripts	Your Collectors
OAuth2 Permissions	Collects delegated + app role assignments	Not collected
PIM Detection	Dual-endpoint for active + eligible roles	May miss eligible roles
Nesting Detail	Explicit parent/child group IDs	Only depth estimates
Membership Path	Direct vs inherited distinction	Not tracked
License Data	SKU lookup and assignment tracking	Not collected
Verdict: Your Architecture is Superior, But Missing Data Points



But I believe you have so far only implemented the License Data components


5) Principals > Users
for the "riskLevel" property, we should add the date. E.g. "thomas@gromedev01.onmicrosoft.com" has a riskState of "dismissed" but i have no idea when the user was tagged as risky or when it was dismissed

6)
6.a) Delta changes show new and modified. 
Does it also show deleted?

7) 
In the dashboard, what does the "lastModified" column actually show? Does it show the last time the principal was modified? If so, I am not sure if it is working when I compare to the Audit tab


8)
Can we collect more details/properties for Administrative Units? Also are Administrative Units considered principals? 

9)
App Protection Policies
Do we also collect data for "Windows Information Protection"? Including what mode they are in i.e. Block Allow Overrides Silent Off?

10)
10.a) I noticed we are not collecting "Privileged access policies"
We should collect that

e.g.
Policy name, Policy type, Scope, approval type, approvers
Task, Exchange, New Move Request, Approval type


10.b) Also what other policies are we missing?
I can already see that we are missing Policies for Microsoft 365 apps
So that is at least one more
We need to compile a list of policies we are not collecting and then address how to implement them


11)
PIM should also collect "justification" 


12)
Subscription under Azure resources should also have a column showing who the owner is. It doesnt have to be a seperate call since it should already be collected in an edges indexing (Right? Isnt it). You can just reference that


---

## Claude's Session Notes (2026-01-09)

### Completed Work

####
Changes Made
CollectUsers/run.ps1:
Added assignedLicenses to the Graph API select fields
Built SKU lookup table from subscribedSkus endpoint
Added license fields to user objects: assignedLicenseSkus, hasP2License, hasE5License, licenseCount
Added license summary stats to function output
Dashboard/run.ps1:
Added license fields to $userPriority so they appear prominently in the Users table
Removed the top-level license summary (since you confirmed the columns show in the table)
Results
The blob data shows license information is being collected correctly:
57 users with P2 licenses (AAD_PREMIUM_P2)
License fields appear in the Users table in the Dashboard
The license data shows in the Users table columns:
hasP2License - boolean flag
hasE5License - boolean flag
licenseCount - number of assigned licenses
assignedLicenseSkus - array of SKU names like ["AAD_PREMIUM_P2"]

#### 1. Audit/Delta Detection - FIXED ✅
**Issue:** Dashboard only showed "new" changeTypes, no "modified" or "deleted"
**Root Cause:**
- Dashboard query `SELECT TOP 200 * FROM c` returned random 200 documents (all happened to be from initial "new" batch)
- Delta detection WAS working correctly (confirmed via DEBUG-DELTA-STATS logs showing 314 modified principals, 580 modified edges, 13 deleted edges)

**Fix:** Changed Dashboard/function.json audit query to:
```sql
SELECT TOP 500 * FROM c ORDER BY c.auditDate DESC
```
Note: Couldn't ORDER BY `changeTimestamp` due to Cosmos DB index limitation.

**Result:** Dashboard now shows: 248 modified, 252 new

#### 2. Groups Table - groupTypeCategory - IN PROGRESS
**What was done:**
- Added `groupTypeCategory` computed field to CollectEntraGroups/run.ps1 (line 235-246)
- Field shows: "Assigned", "Dynamic", or "Microsoft 365"
- Added to IndexerConfigs.psd1 CompareFields and DocumentFields
- Added to Dashboard groupPriority columns
- Needs deploy + re-collection to see results

#### 3. Groups Table - memberCount Column Order - DONE ✅
**Fix:** Updated Dashboard/run.ps1 groupPriority to:
```powershell
@('objectId', 'displayName', 'securityEnabled', 'groupTypes', 'groupTypeCategory', 'memberCountDirect', 'memberCountIndirect', 'memberCountTotal', 'userMemberCount', 'groupMemberCount', 'servicePrincipalMemberCount', 'deviceMemberCount', 'nestingDepth', ...)
```

### Files Modified
- FunctionApp/CollectEntraGroups/run.ps1 - Added groupTypeCategory computation
- FunctionApp/Dashboard/function.json - Fixed audit query ordering
- FunctionApp/Dashboard/run.ps1 - Added groupTypeCategory to groupPriority
- FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1 - Added groupTypeCategory
- FunctionApp/IndexPrincipalsInCosmosDB/run.ps1 - Debug logging
- FunctionApp/IndexEdgesInCosmosDB/run.ps1 - Debug logging
- FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1 - DEBUG-DELTA-STATS logging

### Debug Logs Added
- `DEBUG-DELTA: principalsRawIn contains X existing documents` - Shows input binding count
- `DEBUG-DELTA: edgesRawIn contains X existing edge documents` - Shows edge input binding count
- `DEBUG-DELTA-STATS[entityType]: Total=X, New=X, Modified=X, Deleted=X, Unchanged=X` - Shows delta results

#### 4. App Protection Policies - FIXED ✅
**Issue:** Dashboard shows "No app protection policies found (0 of 272 in container)"
**Root Cause:**
1. **Missing Permission:** `DeviceManagementApps.Read.All` was not granted to the managed identity
   - App Role ID: `7a6ee1e7-141e-4cec-ae74-d9db155731ff`
   - Required for: `iosManagedAppProtections`, `androidManagedAppProtections`, `windowsInformationProtectionPolicies` APIs
2. **Function Bug:** `Invoke-CosmosDbQuery` function in DeriveVirtualEdges/run.ps1 was defined AFTER it was called (PowerShell requires function definitions before calls)
3. **Token Caching:** Function App needed restart after permission grant for managed identity to get fresh token with new permission

**Fixes Applied:**
- Granted `DeviceManagementApps.Read.All` to managed identity `4af7b04d-e57b-4fdd-921f-e9843f8f8e21`
- Moved `Invoke-CosmosDbQuery` function definition to line 35 (before first use)
- Restarted Function App to refresh managed identity token

**Result:** After restart and adding Windows endpoints, collection now returns **6 App Protection policies**:
- Test - App Protection iOS (iOS) - 11 protected apps ✅
- Alpenglow-Test-AppProtection-2c5f6427 (iOS) - 0 protected apps ✅
- Test - App Protection Android (Android) - 12 protected apps ✅
- Test - App Protection (Windows) - 1 protected app ✅
- Test - App Protection Windows New (Windows) - 1 protected app ✅
- Test - Windows Information Protection (WindowsMDM) - 0 protected apps ✅

**IMPORTANT FOR deploy.ps1 / README:**
Add `DeviceManagementApps.Read.All` (`7a6ee1e7-141e-4cec-ae74-d9db155731ff`) to required permissions list.

#### 5. Dashboard - Removed Events Section
Removed the Events tab from the Dashboard HTML as it was a placeholder.
- Removed CONTAINER 5: EVENTS section
- Removed $signIns, $auditEvents, $allEvents, $eventCols variables
- Kept eventsIn binding in function.json for future use
- Renumbered AUDIT section from 6 to 5

### Files Modified (this session)
- FunctionApp/CollectEntraGroups/run.ps1 - Added groupTypeCategory computation
- FunctionApp/Dashboard/function.json - Fixed audit query ordering
- FunctionApp/Dashboard/run.ps1 - Added groupTypeCategory to groupPriority, removed Events section
- FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1 - Added groupTypeCategory
- FunctionApp/IndexPrincipalsInCosmosDB/run.ps1 - Debug logging
- FunctionApp/IndexEdgesInCosmosDB/run.ps1 - Debug logging
- FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1 - DEBUG-DELTA-STATS logging
- FunctionApp/DeriveVirtualEdges/run.ps1 - Moved Invoke-CosmosDbQuery function to before first use

### Debug Logs Added
- `DEBUG-DELTA: principalsRawIn contains X existing documents` - Shows input binding count
- `DEBUG-DELTA: edgesRawIn contains X existing edge documents` - Shows edge input binding count
- `DEBUG-DELTA-STATS[entityType]: Total=X, New=X, Modified=X, Deleted=X, Unchanged=X` - Shows delta results

### Pending Items (from todo list)
1. ~~Fix App Protection policies not showing (0 of 272)~~ - FIXED ✅
2. Implement OAuth2 Permissions collection
3. Implement PIM Detection - dual-endpoint
4. Implement Nesting Detail - explicit parent/child group IDs
5. Implement Membership Path - direct vs inherited

#### 6. Added Windows MAM Endpoints - FIXED ✅
Added additional Windows App Protection endpoints to CollectIntunePolicies/run.ps1:
- `windowsManagedAppProtections` - Newer Windows MAM policies
- `windowsInformationProtectionPolicies` - Classic WIP (without MDM enrollment)
- `mdmWindowsInformationProtectionPolicies` - MDM-based WIP

**All 6 App Protection Policies Now Collected:**
| Policy Name | Platform | Endpoint Used |
|-------------|----------|---------------|
| Test - App Protection iOS | iOS | iosManagedAppProtections ✅ |
| Alpenglow-Test-AppProtection-2c5f6427 | iOS | iosManagedAppProtections ✅ |
| Test - App Protection Android | Android | androidManagedAppProtections ✅ |
| Test - App Protection | Windows | windowsManagedAppProtections ✅ |
| Test - App Protection Windows New | Windows | windowsManagedAppProtections ✅ |
| Test - Windows Information Protection | WindowsMDM | mdmWindowsInformationProtectionPolicies ✅ |

#### 7. BOM Character Fixes - FIXED ✅
**Issue:** PowerShell files had UTF-8 BOM characters that caused parse errors in Azure Functions.
**Error:** `ERROR: The term '﻿#' is not recognized as a name of a cmdlet`

**Files Fixed:**
- FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1 (had double BOM)
- FunctionApp/CollectEntraGroups/run.ps1
- FunctionApp/CollectRelationships/run.ps1
- FunctionApp/Modules/EntraDataCollection/DangerousPermissions.psd1
- FunctionApp/Orchestrator/run.ps1

**Fix Command:**
```bash
# Remove BOM (3 bytes) from file
tail -c +4 "$file" > /tmp/nobom_temp && mv /tmp/nobom_temp "$file"

# Check for BOM
xxd -l 3 "$file" | head -1
# Should NOT start with: efbb bf
```

**Prevention:** Always use UTF-8 without BOM encoding when creating/editing PowerShell files.

---

## Troubleshooting Commands Reference

### Check Blob Storage for Policy Data
```bash
# List recent policy blobs
az storage blob list \
  --account-name "stentrariskv35devenkqnnv" \
  --container-name "raw-data" \
  --auth-mode login \
  --query "[?contains(name, 'policies')].{name:name, modified:properties.lastModified}" \
  -o table | tail -5

# Download and inspect policies blob
az storage blob download \
  --account-name "stentrariskv35devenkqnnv" \
  --container-name "raw-data" \
  --name "TIMESTAMP/TIMESTAMP-policies.jsonl" \
  --auth-mode login \
  --file /tmp/policies.jsonl

# Count policy types in blob
cat /tmp/policies.jsonl | jq -r '.policyType' | sort | uniq -c
```

### Check App Insights Logs
```bash
# Check for errors after collection
az monitor app-insights query \
  --app "appi-entrariskv35-dev-001" \
  --resource-group "rg-entrarisk-v35-001" \
  --analytics-query "traces | where timestamp > ago(15m) | where message contains 'ERROR' | project timestamp, message | order by timestamp desc | take 20" \
  --query "tables[0].rows" -o json | jq -r '.[] | "\(.[0][11:19]): \(.[1][0:200])"'

# Check delta indexing stats
az monitor app-insights query \
  --app "appi-entrariskv35-dev-001" \
  --resource-group "rg-entrarisk-v35-001" \
  --analytics-query "traces | where timestamp > ago(15m) | where message contains 'DEBUG-DELTA-STATS' | project timestamp, message" \
  --query "tables[0].rows" -o json

# Check for MAM/App Protection logs
az monitor app-insights query \
  --app "appi-entrariskv35-dev-001" \
  --resource-group "rg-entrarisk-v35-001" \
  --analytics-query "traces | where timestamp > ago(15m) | where message contains 'MAM' or message contains 'Protection' or message contains '403' | project timestamp, message | order by timestamp desc | take 20" \
  --query "tables[0].rows" -o json
```

### Trigger Collection Manually
```bash
# Get function key
FUNC_KEY=$(az functionapp keys list --name "func-entrariskv35-data-dev-enkqnnv64liny" --resource-group "rg-entrarisk-v35-001" --query "functionKeys.default" -o tsv)

# Trigger orchestrator via HttpTrigger
curl -s -X POST "https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/api/HttpTrigger?code=$FUNC_KEY" -H "Content-Type: application/json" -d '{}'
```

### Check/Grant Graph API Permissions
```bash
# Check managed identity permissions
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/MANAGED_IDENTITY_ID/appRoleAssignments" \
  --headers "Content-Type=application/json" | jq '.value[] | {appRoleId, resourceDisplayName}'

# Key permissions needed:
# - DeviceManagementApps.Read.All (7a6ee1e7-141e-4cec-ae74-d9db155731ff) - For MAM policies
# - DeviceManagementConfiguration.Read.All (dc377aa6-52d8-4e23-b271-2a7ae04cedf3) - For compliance policies
```

### Restart Function App (to refresh token cache)
```bash
az functionapp restart --name "func-entrariskv35-data-dev-enkqnnv64liny" --resource-group "rg-entrarisk-v35-001"
```

### BOM Warning
Do NOT add UTF-8 BOM to PowerShell files. It causes parse errors like:
`ERROR: The term '﻿#' is not recognized`
