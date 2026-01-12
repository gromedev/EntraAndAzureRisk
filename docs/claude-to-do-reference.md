remember that you can refer to /Users/thomas/git/GitHub/EntraAndAzureRisk/Scripts/Entra Scripts for inspiration. Remember that you analyzed:
Aspect	Entra Scripts	Your Collectors
OAuth2 Permissions	Collects delegated + app role assignments	Not collected
PIM Detection	Dual-endpoint for active + eligible roles	May miss eligible roles
Nesting Detail	Explicit parent/child group IDs	Only depth estimates
Membership Path	Direct vs inherited distinction	Not tracked
License Data	SKU lookup and assignment tracking	Not collected


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

**VERIFIED 2026-01-09:** Yes, deleted objects ARE shown in the audit tab. The changeType values found:
- 277 `deleted` entries
- 238 `modified` entries
- 262 `new` entries

7)
In the dashboard, what does the "lastModified" column actually show? Does it show the last time the principal was modified? If so, I am not sure if it is working when I compare to the Audit tab

**INVESTIGATED 2026-01-09:**
- The `lastModified` column currently shows `collectionTimestamp` - when we last collected/indexed the entity
- Microsoft Graph API doesn't provide a `modifiedDateTime` field for most principal types (users, groups, SPs)
- The Audit tab shows `changeTimestamp` - when we detected a change via delta detection
- **These are different concepts:**
  - `lastModified` = when we last touched the record (always updates on each collection)
  - `changeTimestamp` (audit) = when we detected an actual change in the entity

**POTENTIAL IMPROVEMENT:** Only update `lastModified` when a change is actually detected, otherwise preserve the previous value. This would make `lastModified` match the audit's `changeTimestamp` for modified entities.


8)
Can we collect more details/properties for Administrative Units? Also are Administrative Units considered principals? 

9)
App Protection Policies
Do we also collect data for "Windows Information Protection"? Including what mode they are in i.e. Block Allow Overrides Silent Off?

10)
PIM should also collect "justification" 


11)
Subscription under Azure resources should also have a column showing who the owner is. It doesnt have to be a seperate call since it should already be collected in an edges indexing (Right? Isnt it). You can just reference that

12)
12.a) I noticed we are not collecting "Privileged access policies"
We should collect that

e.g.
Policy name, Policy type, Scope, approval type, approvers
Task, Exchange, New Move Request, Approval type


12.b) Also what other policies are we missing?
I can already see that we are missing Policies for Microsoft 365 apps
So that is at least one more
We need to compile a list of policies we are not collecting and then address how to implement them


13)
I also want human friendly names for GUIDs in the data collection/cosmos db/dashboard so that I can easily see 


14)
// DISREGARD FOR NOW THIS IS JUST A PLACEHOLDER
// /Users/thomas/git/GitHub/EntraAndAzureRisk/docs/null-properties.md


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
2. ~~Implement OAuth2 Permissions collection~~ - ALREADY IMPLEMENTED ✅ (Phase 9: oauth2PermissionGrants, Phase 10: appRoleAssignments)
3. ~~Implement PIM Detection - dual-endpoint~~ - ALREADY IMPLEMENTED ✅ (Phase 3: roleEligibilitySchedules + roleAssignmentSchedules)
4. ~~Implement Nesting Detail - explicit parent/child group IDs~~ - ALREADY IMPLEMENTED ✅ (groupNesting hashtable + inheritancePath array)
5. ~~Implement Membership Path - direct vs inherited~~ - ALREADY IMPLEMENTED ✅ (edgeType: groupMember vs groupMemberTransitive, membershipType field)

### Additional Items Completed (this session)
6. Added riskLastUpdatedDateTime to Dashboard userPriority columns ✅
7. Added WIP-specific fields to CollectIntunePolicies (enforcementLevel, wipMode) ✅

#### 8. Added Windows MAM Endpoints - FIXED ✅
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

#### 9. WIP Mode Collection - DONE ✅
Added WIP-specific fields to CollectIntunePolicies/run.ps1 for WindowsInfoProtection and WindowsMDM platforms:
- `enforcementLevel` - Raw value from API (noProtection, encryptAndAuditOnly, encryptAuditAndPrompt, encryptAuditAndBlock)
- `wipMode` - Human-readable mode (Off, Silent, Allow Overrides, Block)
- `protectionUnderLockConfigRequired` - Encrypt under PIN
- `revokeOnUnenrollDisabled` - Keys persist after unenrollment
- `azureRightsManagementServicesAllowed` - Azure RMS enabled
- `iconsVisible` - Overlay icons on protected files
- `indexingEncryptedStoresOrItemsBlocked` - Block Windows Search indexing
- `isAssigned` - Policy is assigned

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

---

## Claude's Session Notes (2026-01-09) - MSGraphPermissions Integration

### Task: Integrate MSGraphPermissions capability into EntraAndAzureRisk

**User Request:** Evaluate https://github.com/Mynster9361/MSGraphPermissions and determine how it could enhance the solution.

### Analysis Summary

**What MSGraphPermissions does:**
- Downloads permission metadata from Microsoft's official Graph DevX Content repo
- Provides functions to lookup least-privileged permissions for any Graph API endpoint
- Enables finding which endpoints a permission grants access to

**Value added to EntraAndAzureRisk:**

| Capability | Current State | With Integration |
|------------|---------------|------------------|
| Dangerous permission detection | 14 hardcoded in DangerousPermissions.psd1 | Same + automated updates |
| Least privilege recommendations | No | Yes |
| Overprivileged app detection | No | Yes |
| Permission-to-endpoint mapping | No | Yes |
| Complete permission catalog | No (only 14 dangerous) | ~500 permissions |

**Key insight:** DangerousPermissions.psd1 and GraphApiPermissions are **complementary**:
- DangerousPermissions = "Is this permission a red flag?" (attack path focus)
- GraphApiPermissions = "What's the minimum needed?" (hygiene/right-sizing focus)

### Files Created

1. **`/docs/MSGraphPermissions-Integration-Plan.md`** - Detailed implementation plan including:
   - Architecture diagrams
   - Data flow
   - Phase-by-phase implementation steps
   - Code snippets for each component
   - New edge types
   - Dashboard changes
   - Testing plan

2. **`Scripts/Update-GraphApiPermissions.ps1`** - Standalone utility script that:
   - Downloads permissions.json from Microsoft's repo
   - Parses the data
   - Generates GraphApiPermissions.psd1
   - **Note:** This is a utility script only - does not modify existing code

### Implementation Plan Summary

**Phase 1: Permission Data & Core Functions**
- Create Update-GraphApiPermissions.ps1 ✅ (created)
- Generate GraphApiPermissions.psd1 (pending)
- Add functions to EntraDataCollection.psm1 (pending)

**Phase 2: Enhanced App Registration Collection**
- Update CollectAppRegistrations to collect detailed permission data (pending)

**Phase 3: Permission Analysis in DeriveEdges**
- Add Phase 5 to DeriveEdges for permission edge generation (pending)
- New edge types: appHasDangerousPermission, appHasHighPrivilegePermission

**Phase 4: Dashboard Integration**
- Add Permission Analysis section to Dashboard (pending)

### Files to Modify (when ready to implement)

| File | Action | Description |
|------|--------|-------------|
| GraphApiPermissions.psd1 | CREATE | Permission data indexed by endpoint |
| EntraDataCollection.psm1 | MODIFY | Add permission lookup functions |
| CollectAppRegistrations/run.ps1 | MODIFY | Enhanced permission collection |
| DeriveEdges/run.ps1 | MODIFY | Add Phase 5 permission analysis |
| Dashboard/run.ps1 | MODIFY | Add Permission Analysis UI |
| IndexerConfigs.psd1 | MODIFY | Add new fields |

### Next Steps (when ready)
1. Run `Update-GraphApiPermissions.ps1` to generate the .psd1 file
2. Follow the implementation plan in `/docs/MSGraphPermissions-Integration-Plan.md`

---

## Claude's Session Notes (2026-01-09) - DeriveEdges Troubleshooting

### Problem Statement
DeriveEdges function runs successfully (`Success: true`) but returns 0 derived edges despite dangerous permissions existing in Cosmos DB.

### Confirmed Facts
1. **Test data exists in Cosmos DB:**
   - App: `DeriveEdges-Test-App-b8db4e6a` (SP ID: `ff3996e3-2879-4394-a788-95000c2a61f0`)
   - User: `DeriveEdges-Test-User-bb0feaf5` with Application Administrator role

2. **Dangerous appRoleAssignment edges confirmed in Dashboard:**
   - `1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9` - Application.ReadWrite.All
   - `9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8` - RoleManagement.ReadWrite.Directory
   - `06b708a9-e830-4db3-a914-8e69da51d44f` - AppRoleAssignment.ReadWrite.All

3. **GUIDs match DangerousPermissions.psd1** - verified exact match

4. **Write-Host doesn't appear in App Insights** - root cause of missing debug logs

### Changes Made (this session)

1. **DeriveEdges/run.ps1** - Changed debug logging from `Write-Host` to `Write-Information`:
   ```powershell
   Write-Information "[DERIVE-DEBUG] Found $($appRoleEdges.Count) appRoleAssignment edges to analyze" -InformationAction Continue
   ```
   Added logging for:
   - Number of edges found
   - Sample edge keys
   - First 5 appRoleIds
   - DangerousPerms keys count
   - Match checking per edge (first 5 only)

2. **Deployment** - Deployed to `func-entrariskv35-data-dev-enkqnnv64liny` at 15:20 UTC

3. **Orchestration Triggered** - ID: `f8f7a0a2-ef07-4d58-a60a-d1da33d717d7`

### Previous Fixes (earlier in session)
- Fixed variable name mismatch in Orchestrator (`$abuseEdgesResult` → `$derivedEdgesResult`)
- Fixed edge type mismatch (`azureRoleAssignment` → `azureRbac`)

### Current Status: PAUSED
Waiting for another session to complete Dashboard changes before continuing.

### Next Steps When Resuming
1. Wait for orchestration `f8f7a0a2-ef07-4d58-a60a-d1da33d717d7` to complete
2. Check App Insights for `[DERIVE-DEBUG]` logs:
   ```bash
   az monitor app-insights query \
     --app "appi-entrariskv35-dev-001" \
     --resource-group "rg-entrarisk-v35-001" \
     --analytics-query "traces | where timestamp > ago(30m) | where message contains 'DERIVE-DEBUG' | project timestamp, message | order by timestamp desc | take 30" \
     --query "tables[0].rows" -o json
   ```
3. Check Dashboard for derived edges (Edges tab → Derived Edges sub-tab)
4. If still 0 edges, analyze the debug output to identify:
   - Is the Cosmos DB query returning edges?
   - Are the appRoleIds present in the edges?
   - Is the DangerousPermissions.psd1 being loaded correctly?
   - Is the ContainsKey check working?

### Key Files
- `/FunctionApp/DeriveEdges/run.ps1` - Main derivation logic (lines 166-232)
- `/FunctionApp/Modules/EntraDataCollection/DangerousPermissions.psd1` - Permission lookups
- `/FunctionApp/Orchestrator/run.ps1` - Calls DeriveEdges (lines 745-800)

### Debug Log Prefixes Added
- `[DERIVE-DEBUG]` - DeriveEdges function debug output

---

## Claude's Session Notes (2026-01-09) - Final Session: Items 10-12 Complete

### Task: Complete remaining items from claude-to-do-reference.md

### Item 10: Collect Privileged Access Policies ✅

**What was done:**
1. Enhanced `CollectPolicies/run.ps1` to extract key settings from roleManagement policy rules into top-level fields:
   - `isApprovalRequired`, `approvalMode`, `primaryApprovers`
   - `maxActivationDuration`, `maxEligibilityDuration`, `maxAssignmentDuration`
   - `isEligibilityExpirationRequired`, `isAssignmentExpirationRequired`
   - `requiresJustification`, `requiresMfa`, `requiresTicketInfo`

2. Added `Get-PolicySettings` helper function to parse the rules array and extract meaningful settings

3. Added Phase 3b to collect PIM Group policies (`scopeType eq 'Group'`) with `policyType: "pimGroupPolicy"`
   - Requires `RoleManagementPolicy.Read.AzureADGroup` permission (graceful skip if not granted)

### Item 11: PIM - Collect Justification Field ✅

**What was done:**
1. Added Phase 3b in `CollectRelationships/run.ps1` to collect PIM role requests with justification
2. New endpoint: `roleManagement/directory/roleAssignmentScheduleRequests`
3. Creates edges with `edgeType: "pimRequest"` containing:
   - `justification` - the user-provided reason for activation
   - `action` - SelfActivate, AdminAssign, etc.
   - `status` - Provisioned, PendingApproval, etc.
   - `scheduleInfo` - timing details
4. Requires `RoleManagement.Read.Directory` permission (graceful skip if not granted)

### Item 12: Subscription Owner Column in Dashboard ✅

**What was done:**
1. Added enrichment logic in `Dashboard/run.ps1` to extract subscription owners from Azure RBAC edges
2. Filters for Owner role GUID: `8e3af657-a8ff-443c-a75c-2fe8c4bcb635`
3. Extracts subscription ID from `scope` field (since `subscriptionId` wasn't previously indexed)
4. Fixed object mutability issue by using JSON deep copy: `$sub | ConvertTo-Json -Depth 10 | ConvertFrom-Json`
5. Added subscription-specific column list `$subsCols` with `owners` as priority column

**Additional fix:** Added `subscriptionId`, `subscriptionName`, `resourceGroup` to edges IndexerConfigs.psd1 so future collections will index these fields directly.

**Result:** Subscription table now shows `thomas (User)` in the owners column ✅

### Files Modified (this session)

| File | Changes |
|------|---------|
| `FunctionApp/CollectPolicies/run.ps1` | Added Get-PolicySettings helper, extracted policy settings to top-level fields, added Phase 3b for PIM Group policies |
| `FunctionApp/CollectRelationships/run.ps1` | Added Phase 3b for PIM role requests with justification |
| `FunctionApp/Dashboard/run.ps1` | Added subscription owner enrichment with JSON deep copy fix |
| `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` | Added subscriptionId, subscriptionName, resourceGroup to edges config |

### Remaining Items (from updated reference doc)

- **Item 12.b**: Compile list of missing policies (Microsoft 365 apps policies, etc.)
- **Item 13**: Human-friendly names for GUIDs in data collection/dashboard
- **Item 14**: Disregarded (placeholder for null-properties.md)

### Key Technical Details

**Cosmos DB object mutability issue:**
Objects from Azure Functions Cosmos DB input bindings are read-only. Using `Add-Member` on them doesn't persist. Solution: Create deep copies using `ConvertTo-Json | ConvertFrom-Json` before modification.

**Subscription ID extraction:**
The `subscriptionId` field wasn't in IndexerConfigs, so Cosmos DB didn't have it. Workaround: Extract from `scope` field which IS indexed: `/subscriptions/{guid}` → `{guid}`

---

## Claude's Session Notes (2026-01-09) - DeriveEdges 401 Fix

### Problem Identified
DeriveEdges was returning 0 derived edges despite dangerous permissions existing in Cosmos DB.

**Root Cause:** The custom `Invoke-CosmosDbQuery` REST API function was failing with **401 Unauthorized**. App Insights logs showed:
```
[DERIVE-DEBUG] Cosmos DB query FAILED: Response status code does not indicate success: 401 (Unauthorized).
```

The auth signature generation in the custom function was incorrect.

### Solution Applied
Changed DeriveEdges from using custom REST API calls to using **Cosmos DB input bindings** (same pattern as Dashboard which works correctly).

### Files Modified

**DeriveEdges/function.json:**
```json
{
  "bindings": [
    { "name": "ActivityInput", "type": "activityTrigger", "direction": "in" },
    {
      "name": "edgesIn",
      "type": "cosmosDB",
      "direction": "in",
      "databaseName": "EntraData",
      "containerName": "edges",
      "connection": "CosmosDbConnectionString",
      "sqlQuery": "SELECT * FROM c WHERE (NOT IS_DEFINED(c.deleted) OR c.deleted = false)"
    },
    { "name": "edgesOut", "type": "cosmosDB", "direction": "out", ... }
  ]
}
```

**DeriveEdges/run.ps1:**
- Removed the custom `Invoke-CosmosDbQuery` function (76 lines)
- Added `$edgesIn` parameter to receive input binding data
- Changed Phase 1-4 to filter from `$edgesIn` instead of querying:
  ```powershell
  # Before (broken):
  $appRoleEdges = Invoke-CosmosDbQuery -Endpoint ... -Query "SELECT * FROM c WHERE c.edgeType = 'appRoleAssignment'"

  # After (fixed):
  $appRoleEdges = @($edgesIn | Where-Object { $_.edgeType -eq 'appRoleAssignment' })
  ```
- Added summary logging at end

### Why Input Bindings Work
- Azure Functions runtime handles Cosmos DB authentication via managed identity / connection string
- Same pattern Dashboard uses successfully
- No custom auth signature generation needed

### Status: ✅ VERIFIED WORKING
- Deployed at 15:55 UTC
- Orchestration `50357921-9433-4a7a-bb61-ee690c2ffa04` completed at ~16:06 UTC
- **51 abuse edges derived successfully!**
- Dashboard shows derived edges: `canAddSecret`, `canModifyGroup`, `canAssignAnyRole`, `isGlobalAdmin`

### Orchestration Summary
```json
{
  "TotalAbuseEdges": 51,
  "TotalDerivedEdges": 51,
  "AllDerivationsSucceeded": true,
  "TotalEdgesIndexed": 2384
}
```

### Derived Edge Types Confirmed in Dashboard
| Edge Type | Source | Description |
|-----------|--------|-------------|
| `canAddSecret` | appOwner/spOwner | Can add credentials to owned apps/SPs |
| `canModifyGroup` | groupOwner | Can modify owned groups |
| `canAssignAnyRole` | Directory role | From privileged roles like Application Administrator |
| `isGlobalAdmin` | directoryRole | Global Administrator role holders |

### Note on Logging
The `[DERIVE-DEBUG]` logs did not appear in App Insights despite using `Write-Information -InformationAction Continue`. This may be a Functions runtime issue with activity functions. However, the function clearly executed successfully based on the orchestration output.

---

## Claude's Session Notes (2026-01-09) - Item 12.b: Missing Policies Analysis

### Task: Compile List of Missing Policies

After researching Microsoft Graph API documentation and the current collectors, here is a comprehensive analysis of what policies exist vs. what we currently collect.

### Currently Collected Policies ✅

| Policy Type | Collector | API Endpoint | policyType Value |
|-------------|-----------|--------------|------------------|
| **Conditional Access** | CollectPolicies | `/identity/conditionalAccess/policies` | `conditionalAccess` |
| **Named Locations** | CollectPolicies | `/identity/conditionalAccess/namedLocations` | `namedLocation` |
| **Role Management (PIM)** | CollectPolicies | `/policies/roleManagementPolicies?$filter=scopeType eq 'DirectoryRole'` | `roleManagement` |
| **Role Management Assignments** | CollectPolicies | `/policies/roleManagementPolicyAssignments` | `roleManagementAssignment` |
| **PIM Group Policies** | CollectPolicies | `/policies/roleManagementPolicies?$filter=scopeType eq 'Group'` | `pimGroupPolicy` |
| **Compliance Policies** | CollectIntunePolicies | `/deviceManagement/deviceCompliancePolicies` | `compliancePolicy` |
| **App Protection (iOS MAM)** | CollectIntunePolicies | `/deviceAppManagement/iosManagedAppProtections` | `appProtectionPolicy` |
| **App Protection (Android MAM)** | CollectIntunePolicies | `/deviceAppManagement/androidManagedAppProtections` | `appProtectionPolicy` |
| **App Protection (Windows MAM)** | CollectIntunePolicies | `/deviceAppManagement/windowsManagedAppProtections` | `appProtectionPolicy` |
| **Windows Information Protection** | CollectIntunePolicies | `/deviceAppManagement/windowsInformationProtectionPolicies` | `appProtectionPolicy` |
| **Windows WIP (MDM)** | CollectIntunePolicies | `/deviceAppManagement/mdmWindowsInformationProtectionPolicies` | `appProtectionPolicy` |

### Missing Policies - High Priority 🔴

These policies are security-critical and should be added:

#### 1. Authentication Methods Policies
**API:** `GET /policies/authenticationMethodsPolicy`
**Permission:** `Policy.Read.All`
**Why Important:** Controls which authentication methods (SMS, FIDO2, Microsoft Authenticator, etc.) are enabled tenant-wide. Critical for MFA security assessment.

**Sub-resources:**
- `/policies/authenticationMethodsPolicy/authenticationMethodConfigurations` - Per-method configuration
- `/policies/authenticationStrengthPolicies` - Authentication strength definitions for CA

#### 2. Security Defaults
**API:** `GET /policies/identitySecurityDefaultsEnforcementPolicy`
**Permission:** `Policy.Read.All`
**Why Important:** Shows if tenant uses security defaults (baseline MFA for all users). Critical for understanding overall security posture.

#### 3. Device Configuration Policies (Settings Catalog)
**API:** `GET /deviceManagement/configurationPolicies`
**Permission:** `DeviceManagementConfiguration.Read.All`
**Why Important:** The new unified endpoint for all device configuration including:
- Endpoint Security policies (Antivirus, Firewall, EDR, ASR)
- Administrative Templates
- Security Baselines
- Feature Updates

**Note:** As of March 2025, this replaces `deviceManagement/templates` and `deviceManagement/intents`.

#### 4. Authorization Policies
**API:** `GET /policies/authorizationPolicy`
**Permission:** `Policy.Read.All`
**Why Important:** Controls guest access, user consent, and default permissions. Includes:
- `allowInvitesFrom` - Who can invite guests
- `guestUserRoleId` - Guest permissions level
- `defaultUserRolePermissions` - What regular users can do

#### 5. Cross-Tenant Access Policies
**API:** `GET /policies/crossTenantAccessPolicy`
**Permission:** `Policy.Read.All`
**Why Important:** Controls B2B collaboration and trust settings with external tenants.

### Missing Policies - Medium Priority 🟡

#### 6. Permission Grant Policies
**API:** `GET /policies/permissionGrantPolicies`
**Permission:** `Policy.Read.All`
**Why Important:** Controls which OAuth permissions users can grant to apps.

#### 7. Token Lifetime Policies
**API:** `GET /policies/tokenLifetimePolicies`
**Permission:** `Policy.Read.All`
**Why Important:** Custom token lifetime settings that may extend session durations.

#### 8. Claims Mapping Policies
**API:** `GET /policies/claimsMappingPolicies`
**Permission:** `Policy.Read.All`
**Why Important:** Custom claims in SAML tokens could indicate SSO misconfiguration.

#### 9. Home Realm Discovery Policies
**API:** `GET /policies/homeRealmDiscoveryPolicies`
**Permission:** `Policy.Read.All`
**Why Important:** Federation settings that control authentication flow.

#### 10. Admin Consent Request Policies
**API:** `GET /policies/adminConsentRequestPolicy`
**Permission:** `Policy.Read.All`
**Why Important:** Shows how app consent requests are handled.

### Missing Policies - Lower Priority (User Mentioned) 🟠

#### 11. Microsoft 365 Apps Policies (Office Cloud Policy Service)
**Note:** The user specifically mentioned this. However, Microsoft 365 Apps policies are managed via the Office Cloud Policy Service (OCPS), which has limited Graph API support. Configuration is primarily through:
- Microsoft 365 Apps admin center
- Group Policy (for hybrid)
- Intune Configuration profiles

**Workaround:** The device configuration policies (`/deviceManagement/configurationPolicies`) can include Office settings when deployed via Intune.

### Not Available via Graph API ❌

These policies cannot be collected via Microsoft Graph:

1. **Data Loss Prevention (DLP) Policy Management** - Can read DLP alerts but cannot read policy definitions
2. **Exchange Transport Rules** - Requires Exchange PowerShell
3. **SharePoint Sharing Policies** - Limited via Graph (`/admin/sharepoint/settings` has partial coverage)
4. **Microsoft Defender Policies** - Some via `securityBaselineTemplate`, but limited

### Recommended Implementation Order

1. **Phase 1 (Security Critical):**
   - Authentication Methods Policy + Authentication Strength
   - Security Defaults
   - Authorization Policy

2. **Phase 2 (Configuration):**
   - Device Configuration Policies (Settings Catalog)
   - Cross-Tenant Access Policy

3. **Phase 3 (Governance):**
   - Permission Grant Policies
   - Admin Consent Request Policy
   - Token Lifetime Policies

### Required Permissions Summary

| New Permission | Policies |
|----------------|----------|
| `Policy.Read.All` | Auth methods, security defaults, authorization, cross-tenant, permission grant, token lifetime, claims mapping, HRD, admin consent |
| `DeviceManagementConfiguration.Read.All` | Device configuration (settings catalog) - **Already granted** |

### References

- [Microsoft Graph Authentication Methods Policy API](https://learn.microsoft.com/en-us/graph/api/resources/authenticationmethodspolicies-overview)
- [Microsoft Graph Security API Overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)
- [Device Management Configuration Policy](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfigv2-devicemanagementconfigurationpolicy)
- [Updates to Beta APIs for Windows Endpoint Security](https://techcommunity.microsoft.com/blog/intunecustomersuccess/updates-to-beta-apis-for-windows-endpoint-security-and-administrative-templates/4357002)

---

## Claude's Session Notes (2026-01-09) - Item 13: Human-Friendly GUID Names

### Task: Add Human-Friendly Names for GUIDs in Dashboard/Data

### Analysis

After analyzing the data, most GUIDs already have human-friendly names:

| Edge Type | GUID Field | Human Name Field | Status |
|-----------|------------|------------------|--------|
| `appRoleAssignment` | `appRoleId` | `appRoleDisplayName` + `appRoleValue` | ✅ Already has names |
| `directoryRole` | `targetRoleTemplateId` | `targetDisplayName` | ✅ Already has names |
| `license` | `targetSkuId` | `targetDisplayName` + `targetSkuPartNumber` | ✅ Already has names |
| **`azureRbac`** | `targetRoleDefinitionId` | `targetRoleDefinitionName` | ❌ **Had GUID, now fixed** |

### Problem Found

Azure RBAC edges showed GUIDs instead of role names:
```json
"targetRoleDefinitionName": "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"  // Should be "Owner"
"targetRoleDefinitionName": "ba92f5b4-2d11-453d-a403-e96b0029c9fe"  // Should be "Storage Blob Data Contributor"
```

### Fix Applied

**File:** [FunctionApp/CollectRelationships/run.ps1](FunctionApp/CollectRelationships/run.ps1)

1. **Added Azure Role Definition Lookup** (lines 696-714):
   - Before processing RBAC assignments, build a lookup table from the first subscription's role definitions
   - Maps role GUID → human-friendly name (e.g., `"8e3af657-a8ff-443c-a75c-2fe8c4bcb635"` → `"Owner"`)

2. **Updated Edge Creation** (lines 745-752, 763):
   - Extract role GUID from the full role definition ID path
   - Look up human-friendly name in the lookup table
   - Fall back to GUID if role not found (handles custom roles from other subscriptions)

### Code Changes

```powershell
# Build Azure Role Definition lookup (GUID -> human-friendly name)
$azureRoleLookup = @{}
if ($subscriptions.Count -gt 0) {
    try {
        $firstSub = $subscriptions[0]
        $roleDefsUri = "https://management.azure.com/subscriptions/$($firstSub.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
        $roleHeaders = @{ 'Authorization' = "Bearer $azureToken"; 'Content-Type' = 'application/json' }
        $roleDefsResponse = Invoke-RestMethod -Uri $roleDefsUri -Method GET -Headers $roleHeaders -ErrorAction Stop
        foreach ($roleDef in $roleDefsResponse.value) {
            $azureRoleLookup[$roleDef.name] = $roleDef.properties.roleName ?? $roleDef.name
        }
        Write-Verbose "Built Azure role lookup: $($azureRoleLookup.Count) role definitions"
    }
    catch {
        Write-Warning "Failed to build Azure role lookup: $_ - role names will show as GUIDs"
    }
}

# In edge creation:
$roleGuid = ($roleDefId -split '/')[-1]
$roleDisplayName = if ($azureRoleLookup.ContainsKey($roleGuid)) {
    $azureRoleLookup[$roleGuid]
} else {
    $roleGuid
}
targetRoleDefinitionName = $roleDisplayName
```

### Result

After re-collection, Azure RBAC edges will show:
```json
"targetRoleDefinitionName": "Owner"
"targetRoleDefinitionName": "Storage Blob Data Contributor"
```

### Status: ✅ Code Fix Applied

**Note:** Requires re-deployment and re-collection to see the updated data. Existing data in Cosmos DB will still show GUIDs until the next collection run.

---

## Future Work: Missing Policies Implementation

The missing policies analysis (Item 12.b) documented 10+ policy types not currently collected. When ready to implement:

1. **Review the analysis** in "Item 12.b: Missing Policies Analysis" section above
2. **Start with Phase 1 (Security Critical):**
   - Authentication Methods Policy + Authentication Strength
   - Security Defaults
   - Authorization Policy
3. **Add `Policy.Read.All` permission** to the managed identity
4. **Follow existing collector patterns** in CollectPolicies/run.ps1

---

## Future Work: Dashboard & Data Quality Tasks

### Audit Tab Issues
- [ ] **Rename tab** - Should be renamed to "Historical Changes" or similar (more descriptive)
- [ ] **Entity types broken** - Currently only shows policies? Investigate what's missing
- [ ] **General audit** - What else could be broken in the audit functionality?

### Events Tab / Audit Log
- [ ] **Events container** - Uses `/eventDate` partition key
- [ ] **Audit log collection** - Be very selective about what audit events to collect
- [ ] **Storage concern** - Without filtering, the container could grow to massive size (1,000,000GB+)
- [ ] **Purpose** - "Enables historical trend analysis, audit correlation, and attack path discovery"
- [ ] **Define scope** - Document exactly which audit events are needed and why

### Temporal Fields Clarity
- [ ] **effectiveFrom/effectiveTo** - These fields exist on all entities for historical queries
- [ ] **Dashboard improvement** - Make temporal fields clearer/more prominent in the dashboard UI
- [ ] **Documentation** - Document how to use temporal fields for historical analysis

### JSONL Optimization
- [ ] **Null handling investigation** - In cases of null values:
  - Does the JSONL include empty properties (e.g., `"field": null`)?
  - Or are null fields omitted entirely?
- [ ] **File size optimization** - If null properties are included, consider omitting them to reduce file size
- [ ] **Measure impact** - Quantify potential storage savings

> **⚠️ DO NOT IMPLEMENT YET:** Before optimizing null handling, we need to first investigate potential bugs that cause null values to be displayed in the dashboard due to errors in the coding logic. Null values appearing may indicate actual collection/indexing issues rather than just storage inefficiency. Fix the root cause bugs first, then optimize.

---

## Priority Task List (2026-01-09)

| Priority | Task | Status |
|----------|------|--------|
| **HIGH** | Missing Policies Phase 1 (Auth Methods, Security Defaults, Authorization) | ✅ Done |
| **HIGH** | Verify lastModified column behavior in dashboard | ✅ Done |
| **HIGH** | Verify deleted objects appear in delta/audit | ✅ Done |
| **MEDIUM** | Administrative Units collection enhancement | ✅ Done |
| **MEDIUM** | Audit tab rename + entity types fix | ✅ Done |
| **MEDIUM** | Missing Policies Phase 2-3 | ✅ Done |

### Administrative Units Enhancement (2026-01-09)
**What was done:**
1. Enhanced `CollectAdministrativeUnits/run.ps1` to collect:
   - Scoped role members (who has delegated admin rights to the AU)
   - Member counts by type (users, groups, devices)
2. Added `auScopedRole` edge type for delegated admin assignments
3. Updated `IndexerConfigs.psd1` with new fields
4. Updated `Dashboard/run.ps1` with new column priority

**New fields on Administrative Units:**
- `memberCountTotal` - Total members in the AU
- `userMemberCount` - Number of user members
- `groupMemberCount` - Number of group members
- `deviceMemberCount` - Number of device members
- `scopedRoleCount` - Number of delegated admin role assignments

**New edge type: `auScopedRole`**
- Captures who has admin privileges scoped to an Administrative Unit
- Fields: `sourceId`, `targetId`, `roleId`, `roleName`
- Example: User X has "User Administrator" role scoped to AU Y

**Required Permission:** `RoleManagement.Read.Directory` (for scoped role collection)


### Missing Policies Phase 2-3 Implementation (2026-01-09)

**What was done:**
Added 4 new policy collection phases to `CollectPolicies/run.ps1`:

1. **Phase 8: Cross-Tenant Access Policy** (`crossTenantAccessPolicy`)
   - API: `/policies/crossTenantAccessPolicy`
   - Fields: `allowedCloudEndpoints`, `default` (B2B collaboration settings)
   - **Result:** 1 policy collected ✅

2. **Phase 9: Permission Grant Policies** (`permissionGrantPolicy`)
   - API: `/policies/permissionGrantPolicies`
   - Fields: `includes`, `excludes`, `includeCount`, `excludeCount`
   - **Status:** 403 - Requires additional permission not granted to managed identity

3. **Phase 10: Admin Consent Request Policy** (`adminConsentRequestPolicy`)
   - API: `/policies/adminConsentRequestPolicy`
   - Fields: `isEnabled`, `notifyReviewers`, `remindersEnabled`, `requestDurationInDays`, `reviewers`
   - **Result:** 1 policy collected ✅

4. **Phase 11: Token Lifetime Policies** (`tokenLifetimePolicy`)
   - API: `/policies/tokenLifetimePolicies`
   - Fields: `isOrganizationDefault`, `definition`
   - **Result:** 0 policies (none exist in tenant)

**Files Modified:**
- `CollectPolicies/run.ps1` - Added Phases 8-11, updated return statement and summary
- `IndexerConfigs.psd1` - Added new policy fields to CompareFields, ArrayFields, DocumentFields
- `Dashboard/run.ps1` - Added new policy tabs: Cross-Tenant, Permission Grant, Admin Consent, Token Lifetime

**Dashboard Verification:**
- Cross-Tenant (1) ✅
- Permission Grant (0) - 403 error, requires `Policy.Read.PermissionGrant` permission (granted 2026-01-09 23:00 UTC, awaiting token refresh)
- Admin Consent (1) ✅
- Token Lifetime (0) - Expected (none exist in tenant - these are custom policies)

**Note:** Token Lifetime Policies show 0 because they only exist when custom token lifetime policies are created. The default token lifetime behavior doesn't create a policy object. This is expected behavior, not a collection issue.

**Permission Grant Policies Status:**
- Permission `Policy.Read.PermissionGrant` (9e640839-a198-48fb-8b9a-013fd6f6cbcd) was granted to managed identity
- Managed identity tokens can take 5-10 minutes to refresh after permission grant
- Once working, should collect 14 Microsoft built-in permission grant policies
- **⚠️ STILL NOT WORKING (2026-01-10):** After multiple restarts and collections, still getting 403. May need to verify the permission grant actually persisted or try a different permission.
- **TODO:** Try granting `Policy.ReadWrite.PermissionGrant` instead if read-only continues to fail

Total policies increased from 282 to 284

**Token Lifetime Policies - REMOVED (2026-01-10):**
Since Token Lifetime Policies only exist as custom policies and this test tenant has none, this is just noise. Consider removing this tab from the Dashboard if it consistently shows 0.

---

# Check regardless of status
echo ""
echo "=== Checking dashboard for entity types ==="
curl -s "https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/api/dashboard?code=hyiuethRJ5prx3Ph0BWHoWgYG73wMSccPg13-FIiZ9aCAzFurZERIw==" > /tmp/dashboard4.html

grep -oE '<td>[a-z]+</td><td>(new|modified|deleted)<' /tmp/dashboard4.html | sed 's/<td>//g' | sed 's/<\/td>.*//g' | sort | uniq -c


---

## New Tasks (2026-01-10)

### 15) Audit - Who Made Changes?
**Question:** Can we show who made the change(s)?
**Research needed:**
- Should we use Entra audit logs for tracking changes?
- Maybe store in events container?
- What would be the most efficient approach?

#### Research Analysis (2026-01-10)

**Current State:**
- Delta detection tracks WHAT changed (new/modified/deleted), but NOT WHO made the change
- The `changes` container stores audit records with `changeType`, `changeTimestamp`, `changedFields`

**Options for "Who Made Changes":**

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **A. Microsoft Audit Logs** | Collect from `/auditLogs/directoryAudits` | Authoritative, includes initiator (user/app), IP, etc. | Large volume, expensive storage, requires filtering |
| **B. Events Container** | Already has partition `/eventDate` | Designed for this purpose | Not yet implemented |
| **C. Sign-In Correlation** | Correlate changes with sign-ins | Approximates who made changes | Not reliable for API/automation changes |

**Recommended Approach: Option A (Microsoft Audit Logs)**
- API: `GET /auditLogs/directoryAudits`
- Permission: `AuditLog.Read.All`
- Filter by categories: `UserManagement`, `GroupManagement`, `ApplicationManagement`, `RoleManagement`, `PolicyManagement`, `DeviceManagement`
- Store in events container with selective filtering (only collect security-relevant events)

**Key Fields to Capture:**
- `initiatedBy.user.userPrincipalName` - Who made the change
- `initiatedBy.app.displayName` - If automation/app made the change
- `targetResources` - What was changed
- `activityDisplayName` - What action was taken
- `result` - Success/failure

**Selective Collection Strategy (to avoid storage explosion):**
Only collect audit events for:
1. Role assignments/activations
2. App consent grants
3. Policy modifications
4. Privileged user/group changes
5. Credential operations (password resets, MFA changes)

---

### 16) isDeleted Column
**Question:** What does the "deleted" column actually show?
- Just that the object hasn't been deleted?
- Isn't it obvious it hasn't been deleted if it's visible in the dashboard?
- Do we need this column?

#### Research Analysis (2026-01-10)

**What `deleted` Does:**
The `deleted` field is part of the **soft-delete mechanism** for historical tracking:

1. When an entity is deleted from Entra ID:
   - `deleted = true` is set
   - `deletedTimestamp` records when
   - `effectiveTo` is set (V3 temporal model)
   - `ttl = 7776000` (90 days) for automatic cleanup

2. Active entities have `deleted = false`

**Why It's Useful:**
- **Historical Analysis:** Query "Show me all users deleted in the last 30 days"
- **Audit Correlation:** Track what was deleted and when
- **Attack Path Analysis:** Identify deleted privileged accounts

**Why It Might Seem Redundant:**
- Dashboard default query filters `deleted != true`, so you don't see deleted objects
- For visible objects, yes it's always `false` or empty

**Recommendation:**
- **Don't remove** - it's essential for historical queries
- **Consider hiding** from default dashboard columns (low priority column)
- Add to `$lowPriorityCols` so it appears at the end

---

### 17) Device Tracking
**Questions:**
1. Do we track who has logged into a device? Not just registered owner/users, but anyone including admins?
2. Do we track LAPS in Intune?
3. Should we use audit logs for device login tracking? Events container?

#### Research Analysis (2026-01-10)

**Current Device Tracking:**
- `CollectRelationships/run.ps1:1213` - Collects `registeredOwners` via `/devices/{id}/registeredOwners`
- Creates `deviceOwner` edges for owner relationships
- Does NOT track registeredUsers or login history

**What's NOT Tracked:**
1. **Device Logins:** Microsoft Graph doesn't have a direct "who logged into device" API
   - Sign-in logs show device info, but not "device → user" direction
   - Would need to correlate sign-ins with device IDs
2. **LAPS:** Windows LAPS data is in Intune via:
   - `GET /deviceManagement/managedDevices/{id}/microsoft.graph.getDeviceLaps()`
   - Requires `DeviceManagementManagedDevices.Read.All` permission
3. **Admin Logins:** Not directly trackable via Graph API

**Options for Device Login Tracking:**

| Approach | API | Feasibility |
|----------|-----|-------------|
| Sign-in logs correlation | `/auditLogs/signIns` with deviceDetail | Medium - requires matching deviceId from sign-ins |
| Intune device info | `/deviceManagement/managedDevices` | Already collected - add `userPrincipalName`, `usersLoggedOn` |
| LAPS passwords | `/deviceManagement/managedDevices/{id}/microsoft.graph.getDeviceLaps()` | NEW - requires implementation |

**LAPS Implementation:**
- API: `GET /deviceManagement/managedDevices/{id}?$select=localAdminPassword,lapsPasswordExpirationDateTime`
- Note: LAPS passwords are sensitive - consider if storing them is appropriate

**Recommendation:**
1. **Enhance CollectDevices** to include Intune `usersLoggedOn` field
2. **Add LAPS collection** (separately) for security assessment
3. **Consider sign-in correlation** for comprehensive device login history (expensive)

---

### 18) Edges > Intune Policy
**Question:** What is this supposed to be exactly? Why do we have it?
- Need to investigate the purpose and if it's working correctly

#### Research Analysis (2026-01-10)

**What "Intune Policy" Edges Are:**
- Edge types: `compliancePolicyTargets`, `compliancePolicyExcludes`, `appProtectionPolicyTargets`, `appProtectionPolicyExcludes`
- Generated by `DeriveVirtualEdges/run.ps1`
- Shows which **groups** are targeted by Intune policies

**Purpose:**
- **Attack Path Analysis:** If User A is in Group X, and Group X is targeted by a compliance policy, we can trace the policy coverage
- **Gap Analysis:** Identify users/devices NOT covered by security policies
- **Impact Assessment:** Which users would be affected if a policy changes?

**How It Works:**
1. `CollectIntunePolicies` collects compliance and app protection policies with `assignments` field
2. `DeriveVirtualEdges` reads policies from Cosmos DB
3. Creates edges: `policy → group` for each assignment

**Edge Example:**
```json
{
    "edgeType": "compliancePolicyTargets",
    "sourceId": "compliance-policy-id",
    "sourceType": "compliancePolicy",
    "targetId": "group-id",
    "targetType": "group",
    "targetDisplayName": "All Users"
}
```

**Is It Working?**
Check Dashboard → Edges → Virtual Edges tab for:
- `compliancePolicyTargets` edges
- `appProtectionPolicyTargets` edges

---

### 19) Empty Tabs - Show Headers ✅ IMPLEMENTED
**Issue:** Tabs with no data show error messages like "No cross-tenant access policy found (0 of 282 in container)"
**Request:** Still want to see the headers/properties that would be collected

#### Implementation (2026-01-10)

**File Modified:** `FunctionApp/Dashboard/run.ps1`

**Change:** Modified `Build-Table` function to always show column headers, even for empty data sets.
- Headers are now built first, before checking if data is empty
- Empty tables show a single row spanning all columns with the "No data" message
- Users can now see which columns/properties would be collected

**Deployment Required:** Deploy function app to see changes in dashboard.

---

### 20) Null vs Blank Values in Derived Edges
**Question:** Why do some properties have null value whereas others are just blank?
- Should blanks also be null values?
- Or is there supposed to be a populated value and something is wrong with the code logic?

#### Research Analysis (2026-01-10)

**Current Behavior:**
- `null` - Property exists but has no value (`"field": null`)
- Blank/empty - Property has empty string (`"field": ""`)
- Missing - Property not included in object

**Root Causes of Inconsistency:**

1. **Source Data Variation:** Graph API returns different formats:
   - Some endpoints return `null`
   - Some return empty string `""`
   - Some omit the field entirely

2. **PowerShell Handling:**
   - `$null -eq ""` returns `false` in PowerShell
   - `$object.property ?? ""` converts null to empty string
   - `$object.property ?? $null` preserves null

3. **Our Code Pattern:**
   ```powershell
   # Current (inconsistent):
   displayName = $entity.displayName ?? ""  # Empty string if null
   description = $entity.description        # null if null
   ```

**Recommendation:**
Standardize on **null for missing values** (not empty strings):
- Cosmos DB handles null efficiently
- Clearer semantics: null = "not available", empty = "intentionally blank"
- Easier filtering: `IS_DEFINED(c.field) AND c.field != null`

**Investigation Needed:**
1. Check specific derived edges with blanks
2. Identify which fields should have values but don't
3. Fix collection logic if values should be populated

---

### 21) Data Collection Performance
**Questions:**
1. Does it make sense collectors are taking so long for a small tenant?
2. Are we utilizing the optimizations in the psm1 module?
3. Test tenant is not realistic - if prohibitively slow here, it will be unusable in enterprise tenants
4. Blob files after each run total under 10MB - is there a bottleneck somewhere?
5. If slower than expected, what could the reason be?

#### Research Analysis (2026-01-10)

**Potential Bottlenecks:**

| Area | Issue | Impact |
|------|-------|--------|
| **Token Acquisition** | Each collector gets fresh tokens | 1-2s per collector × 15+ collectors = 15-30s |
| **Blob Initialization** | Creates empty append blob | Network roundtrip per blob |
| **Cosmos DB Indexing** | Input bindings read ALL existing docs | Grows with data size |
| **Graph API Pagination** | Small batch sizes (100 default) | Many API calls for large datasets |
| **Sequential Orchestration** | Collectors run sequentially | No parallelism |

**Optimizations Already Present:**
✅ `Get-CachedManagedIdentityToken` - 55-minute token cache
✅ `StringBuilder` for JSONL buffering (2MB default)
✅ `Invoke-GraphWithRetry` with exponential backoff
✅ Batch sizes configurable ($batchSize parameter)

**NOT Optimized:**
❌ Collectors run sequentially (could run in parallel for independent data)
❌ Cosmos DB input bindings read all docs (could use change feed instead)
❌ No caching of role definition lookups across collectors
❌ Each blob append requires a network call

**Performance Measurement Needed:**
Add timing logs to identify actual bottleneck:
```powershell
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# operation
Write-Information "[PERF] Operation took $($sw.ElapsedMilliseconds)ms"
```

**Quick Wins:**
1. Run independent collectors in parallel (users, groups, SPs, apps can run simultaneously)
2. Cache role definition lookups (fetch once, share across collectors)
3. Increase blob flush threshold (reduce network calls)

---

### 22) CollectRoleDefinitions Improvements
**Questions:**
1. Is there a better way to handle `privilegedDirectoryRoles` and `privilegedAzureRoles` arrays instead of hardcoding?
2. Does this function overlap with other collectors? Could we consolidate or remove it?
3. Could `/docs/MSGraphPermissions-Integration-Plan.md` provide a better method for role definitions?

#### Research Analysis (2026-01-10)

**Current Implementation:**
- `$privilegedDirectoryRoles`: 13 hardcoded Entra ID role template GUIDs
- `$privilegedAzureRoles`: 15 hardcoded Azure role names
- Used to set `isPrivileged = true` flag on role definitions

**Problems with Hardcoding:**
1. **Maintenance:** New privileged roles require code changes
2. **Completeness:** May miss roles (e.g., no Intune roles, no Dynamics roles)
3. **Context:** "Privileged" depends on scope (Owner at subscription vs resource group)

**Alternative Approaches:**

| Approach | Description | Pros | Cons |
|----------|-------------|------|------|
| **A. Keep Hardcoded** | Current approach | Simple, known set | Manual updates |
| **B. Dynamic from Graph** | Query MS tiering data | Auto-updates | No official API for "privileged" flag |
| **C. Permission Analysis** | Mark roles with dangerous permissions | Data-driven | Complex, requires permission catalog |
| **D. Config File** | Move to `.psd1` config | Easy to update | Still manual |

**Overlap with Other Collectors:**
- `CollectRelationships` - Collects role **assignments** (who has roles)
- `CollectRoleDefinitions` - Collects role **definitions** (what roles exist)
- **No overlap** - they collect different things

**MSGraphPermissions Integration:**
The `/docs/MSGraphPermissions-Integration-Plan.md` focuses on **API permissions** (Graph API scopes), not **directory roles**. However:
- Could add a `RoleCategories.psd1` similar to `DangerousPermissions.psd1`
- Microsoft publishes Tier 0/1/2 role classifications - could codify that

**Recommendation:**
1. **Short-term:** Move arrays to a config file (`PrivilegedRoles.psd1`)
2. **Long-term:** Use Microsoft's official tiering once available via API
3. **Keep function separate** - role definitions vs assignments are distinct concerns

---

### 23) Performance Analysis - COMPLETED (2026-01-10)

**Analysis Run:** Collection on 60 users, 314 SPs, 41 groups

#### Timing Results

| Phase | Duration | Notes |
|-------|----------|-------|
| **Total Orchestration** | ~9 minutes | |
| Data Collection | ~3 min | Runs in parallel |
| Cosmos Indexing | ~6 min | Runs sequentially |

#### Collector Timing (Parallel Phase)

| Collector | Duration | Objects |
|-----------|----------|---------|
| CollectEntraServicePrincipals | 7.4s | 314 SPs |
| CollectEntraGroups | 8.6s | 41 groups |
| CollectDevices | 10.1s | 2 devices |
| CollectIntunePolicies | 10.7s | 0 policies |
| CollectAppRegistrations | 12.2s | 14 apps |
| CollectAdministrativeUnits | 14.4s | 1 AU |
| CollectRoleDefinitions | 15.1s | 133 dir + 833 azure |
| CollectAzureHierarchy | 15.7s | 1 sub, 9 RGs |
| CollectAzureResources | 16.7s | ~50 resources |
| CollectPolicies | 24.0s | CA + Auth Methods, etc. |
| CollectUsers | 32.1s | 60 users |
| CollectEvents | 26.8s | Sign-ins + audit logs |
| **CollectRelationships** | **170.3s** | **BOTTLENECK** |

#### Indexer Timing (Sequential Phase)

| Indexer | Duration | Calls |
|---------|----------|-------|
| IndexPrincipalsInCosmosDB | ~85s total | 5 calls |
| IndexResourcesInCosmosDB | ~15s total | 4 calls |
| **IndexEdgesInCosmosDB** | **~255s total** | **4 calls × ~60s** |
| DeriveEdges | 1.0s | |
| DeriveVirtualEdges | 0.2s | |

#### Root Cause Analysis

**Bottleneck 1: CollectRelationships (170s / 2.8 min)**
- **Root Cause:** ~900+ sequential Graph API calls
- Per-entity API calls:
  - 82 calls for group members (41 groups × 2)
  - 328 calls for owners (14 apps + 314 SPs)
  - 60 calls for user licenses
  - 314 calls for app role assignments
  - 41 calls for group owners

**Bottleneck 2: IndexEdgesInCosmosDB (255s / 4.3 min)**
- **Root Cause:** High Cosmos DB write latency
- Called 4 times × ~60s each

**Bottleneck 3: CollectUsers (32s)**
- **Root Cause:** Large $select fields + risk lookup

#### Optimization Options

| Optimization | Target | Savings |
|--------------|--------|---------|
| **Graph $batch API** | CollectRelationships | ~95% (900→45 calls) |
| **Parallel ForEach** | Per-entity calls | ~80% with throttle 10 |
| **Cosmos parallel writes** | IndexEdgesInCosmosDB | ~76% |
| **Reduced $select** | CollectUsers | ~30% |

#### Projected Improvements

| Scenario | Current | Optimized | Reduction |
|----------|---------|-----------|-----------|
| Small (60 users) | 9 min | ~4 min | 55% |
| Medium (10K users) | 60-90 min | 20-30 min | 67% |
| Large (50K users) | 5-8 hours | 1-2 hours | 75% |

**Priority:** Implement Graph $batch API for CollectRelationships first - biggest impact.

### 24) Alternative Performance Optimization Strategies - ANALYSIS (2026-01-10)

Beyond the Graph $batch API (Task 23's top priority), here are **other optimization strategies** that can be implemented independently or in combination:

---

#### Strategy 1: Cosmos DB Bulk Executor / Parallel Indexing

**Current State:**
- `Write-CosmosParallelBatch` uses `ForEach-Object -Parallel` with 10 threads
- Cosmos DB writes happen after collection completes (sequential indexing)
- Each indexer call takes ~60s for edges

**Optimizations:**

| Approach | Description | Impact |
|----------|-------------|--------|
| **Increase parallelism** | Change `$ParallelThrottle` from 10 to 20-50 | 30-50% faster writes |
| **Bulk import SDK** | Use Cosmos DB Bulk Executor instead of REST | 10-50x faster for large batches |
| **Parallel indexer calls** | Run IndexEdges in parallel with other indexers | ~30% total time reduction |
| **Reduce indexer calls** | Consolidate blob indexing per container | Fewer context switches |

**Implementation:**

```powershell
# Option A: Increase parallelism in Write-CosmosParallelBatch
# Line 983 in EntraDataCollection.psm1
[int]$ParallelThrottle = 25  # Was 10

# Option B: Run indexers in parallel (Orchestrator.ps1 change)
# Instead of sequential:
$edgesIndexResult = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' ...
$policiesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPoliciesInCosmosDB' ...

# Do parallel with -NoWait:
$edgesTask = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' -Input $input -NoWait
$policiesTask = Invoke-DurableActivity -FunctionName 'IndexPoliciesInCosmosDB' -Input $input -NoWait
$results = Wait-ActivityFunction -Task @($edgesTask, $policiesTask)
```

**Estimated Savings:** 30-50% reduction in indexing phase time

---

#### Strategy 2: PowerShell Parallel ForEach for Per-Entity Calls

**Current State:**
- CollectRelationships uses sequential `foreach` loops for per-entity API calls
- Example: 314 SPs × 1 API call each = 314 sequential calls

**Problem Code (CollectRelationships lines 859-880):**
```powershell
foreach ($sp in $spsResponse.value) {
    $ownersResponse = Invoke-GraphWithRetry -Uri ".../$spId/owners" ...  # SEQUENTIAL
}
```

**Optimization:**
```powershell
# Use ForEach-Object -Parallel with throttle limit
$spsResponse.value | ForEach-Object -ThrottleLimit 10 -Parallel {
    $sp = $_
    $spId = $sp.id
    $ownersResponse = Invoke-GraphWithRetry -Uri ".../$spId/owners" ...
}
```

**Note:** This requires careful handling of:
- Shared variables via `$using:`
- StringBuilder thread safety (use concurrent collection or aggregate results)
- Rate limiting (throttle limit respects Graph API limits)

**Estimated Savings:** 80-90% reduction for per-entity loops (~900 calls → ~90 effective calls)

---

#### Strategy 3: Reduce Data Payload Size

**Current State:**
- CollectUsers includes ~40 fields in `$select`
- Large payloads increase network transfer time

**Optimizations:**

| Change | Description | Impact |
|--------|-------------|--------|
| **Minimal $select** | Only fetch required fields | 20-40% faster API calls |
| **Separate heavy fields** | Fetch `authenticationMethods` in parallel sub-query | Removes blocking expansion |
| **Skip null-heavy fields** | Remove fields that are mostly null | Smaller JSON payloads |

**Example (CollectUsers):**
```powershell
# Current: 40+ fields
$selectFields = "userPrincipalName,id,displayName,accountEnabled,..."

# Optimized: Only dashboard-required fields
$selectFields = "id,userPrincipalName,displayName,accountEnabled,createdDateTime,lastSignInDateTime"

# Heavy fields fetched in parallel sub-collector
```

**Estimated Savings:** 20-30% faster collection for large entity types

---

#### Strategy 4: Caching and Lookup Optimization

**Current State:**
- Each collector fetches its own lookup data
- Role definitions fetched multiple times across collectors
- SP lookup happens in CollectRelationships for every OAuth2 grant

**Optimizations:**

| Approach | Description | Impact |
|----------|-------------|--------|
| **Shared lookup cache** | Pass role definitions from CollectRoleDefinitions to other collectors | Eliminates redundant fetches |
| **Pre-fetch SP mapping** | Build SP → App ID map once, reuse | Eliminates 314 individual lookups |
| **Azure Function Output Binding cache** | Use Durable Entity for cross-function state | Architectural change, high impact |

**Implementation:**
```powershell
# In Orchestrator: Pass lookup data to CollectRelationships
$roleDefsResult = Invoke-DurableActivity -FunctionName 'CollectRoleDefinitions' -Input $input
$relInput = @{
    Timestamp = $timestamp
    RoleDefinitions = $roleDefsResult.RoleDefinitions  # Pass cached data
}
$edgesResult = Invoke-DurableActivity -FunctionName 'CollectRelationships' -Input $relInput
```

**Estimated Savings:** 10-15% reduction in redundant API calls

---

#### Strategy 5: Blob Buffer Optimization

**Current State:**
- `Write-BlobBuffer` flushes at 500KB threshold
- Many small flushes = many network calls

**Optimizations:**

| Change | Description | Impact |
|--------|-------------|--------|
| **Increase threshold** | Change 500KB → 2MB | Fewer blob appends |
| **Compression** | Gzip JSONL before write | 60-80% smaller transfers |
| **Single final flush** | Buffer in memory, flush once at end | Eliminates all intermediate flushes |

**Trade-off:** Higher memory usage vs. faster I/O

**Estimated Savings:** 5-10% reduction in blob write overhead

---

#### Strategy 6: Parallel Collector Optimization

**Current State:**
- 13 collectors run in parallel during Phase 1
- BUT: CollectRelationships runs in Phase 2 alone (170s blocking)

**Optimization:**
- Split CollectRelationships into smaller, independent activities
- Run relationship collectors in parallel with entity collectors

**Example:**
```
Current:
Phase 1 (parallel): Users, Groups, SPs, Devices, Apps, ... (32s)
Phase 2 (serial): CollectRelationships (170s) ← BOTTLENECK

Optimized:
Phase 1 (parallel):
  - Users, Groups, SPs, Devices, Apps...
  - CollectGroupMemberships (parallel)
  - CollectOwners (parallel)
  - CollectRoleAssignments (parallel)
  - CollectOAuth2Grants (parallel)
```

**Complexity:** High - requires splitting CollectRelationships into ~5 smaller functions

**Estimated Savings:** 50-70% reduction if fully parallelized

---

#### Comparison Matrix

| Strategy | Complexity | Savings | Risk | Dependencies |
|----------|------------|---------|------|--------------|
| Graph $batch API | Medium | **~95%** | Low | Graph API |
| Cosmos parallel increase | **Low** | 30-50% | Low | None |
| PowerShell parallel foreach | Medium | 80-90% | Medium | Thread safety |
| Reduce $select fields | **Low** | 20-30% | Low | Dashboard compatibility |
| Caching/lookup optimization | Medium | 10-15% | Low | Orchestrator changes |
| Blob buffer increase | **Low** | 5-10% | Low | Memory usage |
| Split CollectRelationships | **High** | 50-70% | High | Major refactor |

---

#### Quick Wins (Low Effort, Immediate Impact)

1. **Increase Cosmos parallelism** - Change `$ParallelThrottle = 25` in Write-CosmosParallelBatch
2. **Increase blob buffer** - Change threshold from 500KB to 2MB
3. **Trim $select fields** - Remove rarely-used fields from CollectUsers

These can be implemented in < 1 hour and provide 15-25% improvement.

---

## Tasks Ranked by Implementation Difficulty (2026-01-12)

Ranked from **easiest** (least likely to break anything) to **hardest** (significant refactoring).

### 🟢 TIER 1: TRIVIAL (< 10 lines, config changes only)

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 1 | Increase Cosmos parallelism to 25 | ✅ Done | `$ParallelThrottle = 25` in EntraDataCollection.psm1 | None |
| 2 | Increase blob buffer to 2MB | ✅ Done | `$writeThreshold = 2000000` in 6 collectors | None |
| 3 | Hide isDeleted column | ✅ Done | Already in `$excludeFields` array | None |
| 4 | Remove V3.5/AI-generated comments | ✅ Done | Removed 60+ references | None |

### 🟡 TIER 2: EASY (10-50 lines, isolated changes)

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 5 | Trim $select fields across all collectors | ✅ Done | Removed 16 rarely-used fields across 5 collectors - 2026-01-12 | None |
| 6 | Move helper functions to psm1 module | Pending | Copy/paste functions, add Export-ModuleMember | Low |
| 7 | Groups groupTypeCategory | ✅ Done | Already implemented - deployed 2026-01-12 | None |
| 8 | ~~Move privileged roles to config file~~ | N/A | CollectRoleDefinitions removed - see Task #40 | None |
| 9 | Optimize JSONL - exclude null properties | Pending | Add filter before JSON conversion | Low |

### 🟠 TIER 3: MODERATE (50-150 lines, multiple files)

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 10 | Add usersLoggedOn to device tracking | Pending | Add field to CollectDevices, IndexerConfigs, Dashboard | Low |
| 11 | Enhance Historical Changes tab | ✅ Done | Added sub-tabs: All, Principals, Policies, Resources, Edges - 2026-01-12 | Medium |
| 12 | Rename Dashboard + add debug metrics | ✅ Done | Renamed + added debug metrics (data age, newest/oldest timestamps, change breakdown, data quality checks) - 2026-01-13 | Medium |
| 13 | Investigate Dashboard > Role Policies | ✅ Done | Investigation: Working as designed, filters roleManagement* policyTypes - 2026-01-12 | None |
| 14 | Audit edges and data points | ✅ Done | Investigation: Dynamic columns already filter empty values via Get-AllColumns - 2026-01-12 | None |
| 15 | ~~Investigate Dashboard > Azure Roles~~ | ✅ Done | Removed entirely - see Task #40 | None |
| 16 | Investigate Edges > Intune Policies | ✅ Done | BUG FIXED: DeriveVirtualEdges query used `c.deleted != true` which doesn't match undefined. Changed to `(NOT IS_DEFINED(c.deleted) OR c.deleted = false)` - 2026-01-13 | None |
| 38 | Review collector frequencies | Pending | Depends on #17 (Delta Query) - see consistency risks | Low |
| 39 | Investigate risky sign-ins vs risky users | Pending | Does `/auditLogs/signIns` add value over existing `riskLevel` field? | Low |
| 40 | ~~Replace CollectRoleDefinitions with static file~~ | ✅ Done | **REMOVED ENTIRELY** - Role definitions are static reference data, nothing depends on them. Saves API calls, Cosmos writes, 5MB dashboard payload. 2026-01-12 | None |

### 🔴 TIER 4: SIGNIFICANT (150-500 lines, architectural changes)

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 17 | Implement Graph Delta Query API. Investigate using e.g. /users/delta instead of /users to get only changed entities. The devices Graph API also has delta capabilities. What else in the solution can use delta endpoints? | Pending | See `/docs/Epic 0-plan-delta-Architecture.md` | Medium |
| 18 | Audit - Who Made Changes feature | Pending | New collection from /auditLogs/directoryAudits | Medium |
| 19 | Expand Intune/Devices collection | Pending | New API calls (ASR, Settings catalog, Baselines, etc) | Medium |
| 20 | Null vs Blank values fix | ✅ Done | INVESTIGATION COMPLETE: Dashboard shows 0 empty cells, 0 quality issues. `?? ""` pattern (310 occurrences) is intentional for clean display. Enrichment logic working for RBAC edges. No action needed - 2026-01-13 | None |

### ⛔ TIER 5: MAJOR (500+ lines, refactoring required)

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 21 | **Graph $batch API** | ✅ Done | Implemented `Invoke-GraphBatch` - 95% API call reduction across 4 collectors - 2026-01-12 | High |
| 22 | Inverstigate attack path features | Pending | New algorithms for edge weights, path scoring | High |
| 23 | Evaluate Purview integration | Pending | New integration, APIs, data model - see Epic 3-Purview DLP 2.md | High |

### 📤 TIER 2.5: DASHBOARD EXPORT FEATURE

| # | Task | Status | Change Required | Risk |
|---|------|--------|-----------------|------|
| 41 | **Dashboard Export to CSV/JSON** | ✅ Done | Added CSV/JSON export buttons to all 5 sections, filenames include tab name (e.g., principals-users.csv) - 2026-01-12 | Low |
| 42 | **Audit completed tasks for accuracy** | ✅ Done | **AUDIT COMPLETED 2026-01-13** - See findings below | High |

### Task 42 Audit Findings (2026-01-13)

#### DATA INTEGRITY VERIFICATION (Blob vs Dashboard)

**Verified via `az storage blob download` and dashboard comparison:**

| Container | Blob Count | Dashboard Count | Status |
|-----------|------------|-----------------|--------|
| Principals | 448 (U:70 G:52 SP:323 D:2 AU:1) | 448 | ✅ Match |
| Policies | 303 | 303 | ✅ Match |
| Edges (raw) | 692 | 745 | ⚠️ +53 derived edges added by DeriveEdges |

**Policy type breakdown verified:**
- Conditional Access: 5 ✓
- Role Policies: 266 (133+133) ✓
- App Protection: 7 ✓
- All other types match ✓

#### DATA QUALITY ISSUES FOUND AND FIXED (2026-01-13)

| Issue | Severity | Fix Applied |
|-------|----------|-------------|
| **azureRbac sourceDisplayName = null** | HIGH | ✅ FIXED - Added enrichment logic in Dashboard to lookup principal names from allPrincipals |
| **Missing edge type tabs** | MEDIUM | ✅ FIXED - Added 4 new tabs: AU Scoped Roles (2), PIM Requests (0), OAuth2 Grants (9), Role Policy (133) |
| **Summary bar missing AU** | LOW | ✅ FIXED - Added AU count to summary bar |
| **Syntax error in run.ps1** | HIGH | ✅ FIXED - Corrected `$policyChanges ""=` to `$policyChanges =` |

**Verification commands used:**
```bash
# Verify RBAC enrichment - now shows "thomas" instead of null
curl -s "DASHBOARD_URL" | grep -E "rbac-tbl" -A 50 | grep -oE '<td>[^<]+</td>' | head -10

# Verify new edge tabs visible
curl -s "DASHBOARD_URL" | grep -E "AU Scoped|OAuth2|PIM Requests|Role Policy"
```

#### CODE + RUNTIME VERIFICATION (2026-01-13)

**RUNTIME VERIFIED via curl/grep commands:**
| Task | Verification Command | Result |
|------|---------------------|--------|
| 3 - Hide isDeleted column | `curl ... \| grep 'isDeleted</th>'` | ✅ 0 matches - column hidden |
| 7 - groupTypeCategory | `curl ... \| grep 'Assigned\|Dynamic\|Microsoft 365'` | ✅ 41 Assigned, 5 Dynamic, 6 M365 |
| 11 - Historical sub-tabs | `curl ... \| grep 'audit-section' -A 30` | ✅ All(500), Principals(23), Policies(17), Resources(1), Edges(459) |
| 12 - Debug metrics | `curl ... \| grep 'Debug Metrics'` | ✅ Data Age: 59.8 min, realistic timestamps, +0/~60/-440 |
| 21 - Invoke-GraphBatch | `grep 'Invoke-GraphBatch'` across FunctionApp | ✅ 11+ calls in 4 collectors |
| 40 - CollectRoleDefinitions | `ls FunctionApp/ \| grep role` | ✅ Folder does not exist |
| 41 - CSV/JSON export | `curl ... \| grep 'exportTo'` | ✅ Functions and buttons present |

**CODE EXISTS (not runtime verified):**
| Task | Verification Method | Status |
|------|---------------------|--------|
| 1 - Cosmos parallelism 25 | `$ParallelThrottle = 25` in EntraDataCollection.psm1:1252 | ✅ Code exists |
| 2 - Blob buffer 2MB | `$writeThreshold = 2000000` in 6 collectors | ✅ Code exists |
| 5 - Trim $select fields | $select fields present in all collectors | ✅ Code exists |

**ISSUES FOUND AND FIXED:**
| Issue | Problem | Fix Applied |
|-------|---------|-------------|
| Audit ORDER BY missing | Dashboard audit query was `SELECT TOP 500 * FROM c` - missing `ORDER BY c.auditDate DESC`. All records showed as "new" | Fixed in Dashboard/function.json - added ORDER BY |
| Task 12 incomplete | Debug metrics weren't added, only title rename | Fixed - added data age, timestamps, change breakdown, quality checks |

**NOTE:** The "Verify deleted objects appear in delta/audit" verification on 2026-01-09 may have been coincidentally correct due to random document selection, but the fix wasn't persistent. Now properly fixed with ORDER BY clause.

**Details for Task #41:**
- Export should use **dashboard column order** (not raw JSONL property order)
- Categories to support: Principals (Users, Groups, SPs, Devices, AUs), Resources (Apps, Azure), Edges (by type), Policies
- Format options: CSV and/or JSON
- Implementation approach:
  - The `$xxxPriority` arrays in Dashboard/run.ps1 already define column order (e.g., `$userPriority`, `$groupPriority`)
  - Add JavaScript export function that respects these column orderings
  - CSV: Use column headers in priority order, output rows in same order
  - JSON: Output array of objects with keys ordered per priority array
- Example JSONL input vs Dashboard output:
  ```
  JSONL order: resourceBehaviorOptions, deviceMemberCount, expirationDateTime, groupMemberCount, ...
  Dashboard order: objectId, displayName, securityEnabled, groupTypes, groupTypeCategory, memberCountDirect, ...
  ```
- Export should match what user sees in the table (filtered, sorted, column-ordered)

### Implementation Strategy

**Completed:** Tier 1 (all 4 items) - 2026-01-12
**Next:** Work through Tier 2 items (5 tasks, low risk)
**Then:** Tier 3 moderate changes
**Finally:** Tier 4-5 when architecture is stable

---

## Alpenglow Dashboard - Separation & Design

### Architecture Overview

The current "Debug Dashboard" in Function App 1 will remain for developer/debugging purposes.
A new "Alpenglow Dashboard" will be created as a separate Function App 2 with:
- Read-only Cosmos DB + Blob permissions (no Graph API)
- Independent scaling and deployment
- Security isolation from data collection components

**Reference Documents:**
- Architecture: `/docs/final architecture.md`
- UI Design: `/docs/Website 2 Design.md`

### Dashboard Separation Tasks

| # | Task | Status | Notes |
|---|------|--------|-------|
| 25 | Rename current Dashboard to "Debug Dashboard" in UI | Pending | Update HTML title and header |
| 26 | Create Function App 2 infrastructure (Bicep/ARM) | Pending | Separate Function App for Alpenglow Dashboard |
| 27 | Extract Dashboard function to new Function App | Pending | Copy Dashboard folder + dependencies |
| 28 | Configure Managed Identity with read-only Cosmos access | Pending | No Graph API permissions |
| 29 | Update deployment scripts for multi-Function App deploy | Pending | deploy.ps1 modifications |

### Design Refinement Tasks

| # | Task | Status | Notes |
|---|------|--------|-------|
| 30 | Design relationship visualization strategy | Pending | How to show edges without Gremlin - tables, matrix, mini-graphs? |
| 31 | Define historical trends implementation | Pending | Chart.js/SVG, data sources, 90-day trend storage |
| 32 | Finalize landing page security posture cards | Pending | 5 cards: Privileged Access, Auth, CA, Azure, Apps |
| 33 | Design detail panel interactions | Pending | Slide-in panels, entity drill-down |
| 34 | Create static demo site specification | Pending | Synthetic data, tech stack, GitHub Pages hosting |

### Future Components (V4+)

| # | Task | Status | Notes |
|---|------|--------|-------|
| 35 | Plan Function App 3 (Graph Operations) | Deferred | Gremlin projection + snapshot generation |
| 36 | Plan Azure AI Foundry Agent integration | Deferred | Natural language query interface |

---

---

## Session Log: 2026-01-12 (Performance Quick Wins)

### Tasks Completed

1. **Cosmos Parallelism Increased** (10 → 25)
   - File: `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1:983`
   - Change: `$ParallelThrottle = 25`

2. **Blob Buffer Thresholds Increased to 2MB**
   - Updated 6 collector files from 3000-5000 to 2,000,000 characters
   - Files: CollectDevices, CollectUsers, CollectAppRegistrations, CollectRelationships, CollectEntraServicePrincipals, CollectEntraGroups

3. **V3.5 References Removed** (~60+ occurrences)
   - Dashboard: Title, header, inline comments
   - Orchestrator: Header, Write-Verbose, inline comments
   - Collectors: Header documentation
   - IndexerConfigs.psd1: Field comments

4. **isDeleted Column** - Already hidden (was in $excludeFields)

### Deployment & Verification

- Deployed via `func azure functionapp publish`
- Triggered collection: `cf94fe28-f20d-413f-ad4d-a1f5507d9b8f`
- Collection completed in ~10 minutes
- Dashboard verified working with cleaned up UI

### Performance Analysis: On-Prem Scripts vs Azure Functions

The on-prem scripts use `ForEach-Object -Parallel` for parallel processing. However, **Graph $batch API** is more efficient:

| Approach | API Calls | Wall Time |
|----------|-----------|-----------|
| Sequential | 900 | ~170s |
| Parallel (10 threads) | 900 | ~17s |
| $batch API | 45 | ~10s |
| $batch + Parallel | 45 | ~5s |

**Recommendation:** ~~Implement Graph $batch API first (Task #1), then add ForEach-Object -Parallel for additional gains.~~ **DONE - See session log below.**

---

## Session Log: 2026-01-12 (Graph $batch API Implementation)

### Task #21 Completed: Graph $batch API

Implemented Microsoft Graph $batch API to reduce API calls by 95% across 4 collectors.

### Files Modified

| File | Change |
|------|--------|
| `EntraDataCollection.psm1` | Added `Invoke-GraphBatch` function (~230 lines) |
| `CollectUsers/run.ps1` | Batched auth methods + MFA requirements |
| `CollectRelationships/run.ps1` | Batched 6 phases (licenses, owners, assignments) |
| `CollectAppRegistrations/run.ps1` | Batched federatedIdentityCredentials |
| `CollectAdministrativeUnits/run.ps1` | Batched members + scopedRoleMembers |

### API Call Reduction (Medium Tenant - 10K users)

| Collector | Before | After | Reduction |
|-----------|--------|-------|-----------|
| CollectUsers | 20,022 | ~1,000 | **95%** |
| CollectRelationships | 17,641 | ~900 | **95%** |
| CollectAppRegistrations | 1,001 | ~50 | **95%** |
| CollectAdministrativeUnits | 100 | ~5 | **95%** |
| **TOTAL** | **38,904** | **~2,000** | **95%** |

### `Invoke-GraphBatch` Function Features

- Batches up to 20 requests per $batch call (Graph API limit)
- Automatic chunking for larger request sets
- Supports both v1.0 and beta API versions
- Retry logic for 429 (rate limiting) and 5xx errors
- Returns hashtable keyed by request ID

### Deployment & Verification

- Deployed via: `func azure functionapp publish func-entrariskv35-data-dev-enkqnnv64liny --powershell`
- Instance ID: `837c670d-2d73-42a2-bc2a-50ae12f0e100`
- Dashboard URL: https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/api/dashboard?code=hyiuethRJ5prx3Ph0BWHoWgYG73wMSccPg13-FIiZ9aCAzFurZERIw==

### Verified Performance Results (2026-01-12T13:23:47Z)

**Batched Phase Timing (CollectRelationships):**
| Phase | Duration | Description |
|-------|----------|-------------|
| Phase6_AppOwners | 427 ms | 14 apps |
| Phase7_SpOwners | 5.8 sec | 316 SPs |
| Phase8_UserLicenses | 1.0 sec | 60 users |
| Phase10_AppRoleAssignments | 3.4 sec | 64 assignments |
| Phase11_GroupOwners | 597 ms | 16 owners |
| Phase12_DeviceOwners | 218 ms | 2 devices |
| **TOTAL** | **~12 sec** | Batching working as expected |

**Collection Summary:**
- Total Principals: 420 (60 users, 41 groups, 316 SPs, 2 devices, 1 AU)
- Total Edges: 577 relationships
- Total Resources: 45
- Total Policies: 298

**Issue Fixed:** Module manifest (`.psd1`) was missing new exports (`Invoke-GraphBatch`, `New-PerformanceTimer`). Updated `FunctionsToExport` array.

### Remaining Optimization Opportunities

| Priority | Feature | Impact | Status |
|----------|---------|--------|--------|
| 1 | **Indexing optimization** | High | ✅ Done - 96% reduction (8,425 → 320 writes) |
| 2 | Conditional Collection (Phase 2) | Very High | Only fetch auth for changed users |
| 3 | Delta Queries (Phase 3) | Medium | Enables conditional collection |

Implement Graph Delta Query API. Investigate using e.g. /users/delta instead of /users to get only changed entities. The devices Graph API also has delta capabilities. What else in the solution can use delta endpoints?

---

## Session Log: 2026-01-12 (Indexing Optimization)

### Task #22 Completed: Indexing Optimization

Achieved **96.2% reduction** in Cosmos DB writes per collection run (8,425 → 320).

### Bugs Fixed

| Bug | Impact | Fix |
|-----|--------|-----|
| **Principals indexer reads all types** | 420×5=2100 entities, all marked "New" | Added `FilterByPrincipalType` parameter to `Invoke-DeltaIndexing` |
| **SQL queries missing fields** | False "Modified" detections | Changed indexer function.json files to `SELECT * FROM c` |
| **Policies duplicate indexer call** | 298×2=596 policies processed | Consolidated to single indexer call in Orchestrator |
| **policyType array filtering** | Other policy types marked "New" | Detect ALL policyTypes in blob before filtering |
| **Derived edges random GUIDs** | Duplicates instead of upserts | Use `objectId` as document `id` |
| **rules/effectiveRules comparison** | 133 policies always "Modified" | Removed from CompareFields (complex nested arrays) |

### Files Modified

| File | Change |
|------|--------|
| `EntraDataCollection.psm1` | Added FilterByPrincipalType parameter, policyType array detection |
| `IndexerConfigs.psd1` | Removed rules/effectiveRules from CompareFields |
| `IndexPrincipalsInCosmosDB/function.json` | Changed to `SELECT * FROM c` |
| `IndexEdgesInCosmosDB/function.json` | Changed to `SELECT * FROM c` |
| `IndexPoliciesInCosmosDB/function.json` | Changed to `SELECT * FROM c` |
| `IndexResourcesInCosmosDB/function.json` | Changed to `SELECT * FROM c` |
| `DeriveEdges/function.json` | Changed to `SELECT * FROM c` (consistent) |
| `Orchestrator/run.ps1` | Consolidated policies indexer call |
| `DeriveEdges/run.ps1` | Fixed 6 occurrences of id generation |
| `DeriveVirtualEdges/run.ps1` | Fixed 7 occurrences of id generation |

### Results After Fix

| Entity Type | Writes | Notes |
|-------------|--------|-------|
| Principals | 2 | Real changes only (from random test script) |
| Policies | 1 | Real changes only |
| Resources | 0 | Stable |
| Edges | ~314 | Derived edge upserts (not duplicates) |
| **Total** | **~320** | **96% reduction from 8,425** |

### Code Changes

**FilterByPrincipalType in EntraDataCollection.psm1:**
```powershell
# New parameter added to Invoke-DeltaIndexing
[Parameter()]
[string]$FilterByPrincipalType  # Filter blob entities to only this principalType

# Filter current entities BEFORE delta detection
if ($FilterByPrincipalType) {
    $filteredEntities = @{}
    foreach ($objectId in $currentEntities.Keys) {
        $entity = $currentEntities[$objectId]
        if ($entity.principalType -eq $FilterByPrincipalType) {
            $filteredEntities[$objectId] = $entity
        }
    }
    $currentEntities = $filteredEntities
}
```

**Deterministic Edge IDs in DeriveEdges/run.ps1:**
```powershell
# Before: id = [guid]::NewGuid().ToString() (creates duplicates)
# After: Use objectId as id so Cosmos upserts instead of creating duplicates
$derivedObjectId = "$($edge.sourceId)_$($permInfo.TargetType)_$($permInfo.AbuseEdge)"
$abuseEdge = @{
    id = $derivedObjectId
    objectId = $derivedObjectId
    # ...
}
```

---

# useful commands
STATUS=$(curl -s "https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/runtime/webhooks/durabletask/instances/79eec71c-9021-4cb3-97e7-f429de1e38df?taskHub=EntraRiskHub&connection=AzureWebJobsStorage&code=H85CnWqn2Naz4LZfUM9s6r1lhh9SI-67BTpFFIqhstFOAzFu91rYfQ==" | jq -r '.runtimeStatus')
echo "Status: $STATUS"