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


---

## Claude's Session Notes (2026-01-09)

### Completed Work

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

### Pending Items (from todo list)
1. Fix App Protection policies not showing (0 of 272)
2. Implement OAuth2 Permissions collection
3. Implement PIM Detection - dual-endpoint
4. Implement Nesting Detail - explicit parent/child group IDs
5. Implement Membership Path - direct vs inherited