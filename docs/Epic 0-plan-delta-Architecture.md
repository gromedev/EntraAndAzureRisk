# Delta Query Architecture - Design Document

**Version**: 2.0
**Created**: 2026-01-12
**Status**: Planning
**Related Tasks**: #17 (Delta Query API), #38 (Collector Frequencies)

---

## Purpose

Evaluate Microsoft Graph delta queries for potential API call reduction. This document is based on **actual code analysis** of the V3.5 collectors.

---

## Current API Call Analysis (Actual Code)

### CollectUsers - The Big One

**Code location**: [CollectUsers/run.ps1](../FunctionApp/CollectUsers/run.ps1)

| API Call | Type | Count Formula | For 1,000 Users |
|----------|------|---------------|-----------------|
| `/identityProtection/riskyUsers` | Bulk (paginated) | ~1-2 | 2 |
| `/subscribedSkus` | Single | 1 | 1 |
| `/users` | Bulk (paginated) | users/999 | 2 |
| `/users/{id}/authentication/methods` | **Per-user** | 1 per user | **1,000** |
| `/users/{id}/authentication/requirements` | **Per-user** | 1 per user | **1,000** |

**Total for 1,000 users: ~2,005 API calls**
**Total for 10,000 users: ~20,005 API calls**

### CollectRelationships - The Complex One

**Code location**: [CollectRelationships/run.ps1](../FunctionApp/CollectRelationships/run.ps1)

| Phase | API Call | Type | Count Formula | For 100 groups, 200 apps, 300 SPs, 1000 users, 100 devices |
|-------|----------|------|---------------|-------------------------------------------------------------|
| 1 | `/groups` | Bulk | ~1 | 1 |
| 1 | `/groups/{id}/members` | **Per-group** | 1 per group | **100** |
| 1b | `/groups/{id}/transitiveMembers` | **Per-group** | 1 per group | **100** |
| 2 | `/roleManagement/directory/roleAssignments` | Bulk | ~1-2 | 2 |
| 3 | `/roleManagement/directory/roleEligibilitySchedules` | Bulk | ~1 | 1 |
| 3 | `/roleManagement/directory/roleAssignmentSchedules` | Bulk | ~1 | 1 |
| 3b | `/roleManagement/directory/roleAssignmentScheduleRequests` | Bulk | ~1 | 1 |
| 4 | `/groups?$filter=isAssignableToRole` | Bulk | ~1 | 1 |
| 4 | `/identityGovernance/privilegedAccess/group/eligibilitySchedules` | **Per role-assignable group** | varies | ~10 |
| 4 | `/identityGovernance/privilegedAccess/group/assignmentSchedules` | **Per role-assignable group** | varies | ~10 |
| 5 | `/subscriptions` | Bulk | 1 | 1 |
| 5 | Azure RBAC per subscription | **Per-subscription** | 1 per sub | ~5 |
| 6 | `/applications` | Bulk (paginated) | ~1 | 1 |
| 6 | `/applications/{id}/owners` | **Per-app** | 1 per app | **200** |
| 7 | `/servicePrincipals` | Bulk (paginated) | ~1 | 1 |
| 7 | `/servicePrincipals/{id}/owners` | **Per-SP** | 1 per SP | **300** |
| 8 | `/users` | Bulk (paginated) | ~1 | 1 |
| 8 | `/users/{id}/licenseDetails` | **Per-user** | 1 per user | **1,000** |
| 9 | `/servicePrincipals` (for lookup) | Bulk | ~1 | 1 |
| 9 | `/oauth2PermissionGrants` | Bulk | ~1-2 | 2 |
| 10 | `/servicePrincipals` | Bulk | ~1 | 1 |
| 10 | `/servicePrincipals/{id}/appRoleAssignedTo` | **Per-SP** | 1 per SP | **300** |
| 11 | `/groups/{id}/owners` | **Per-group** | 1 per group | **100** |
| 12 | `/devices` | Bulk | ~1 | 1 |
| 12 | `/devices/{id}/registeredOwners` | **Per-device** | 1 per device | **100** |
| 13 | `/identity/conditionalAccess/policies` | Bulk | ~1 | 1 |
| 14 | `/policies/roleManagementPolicyAssignments` | Bulk | ~1 | 1 |
| 14 | `/policies/roleManagementPolicies/{id}` | **Per-policy** | varies | ~20 |

**Total for small tenant: ~2,250 API calls**

### Other Collectors (Smaller Impact)

| Collector | API Pattern | Typical Calls |
|-----------|-------------|---------------|
| CollectEntraGroups | Bulk only | ~5-10 |
| CollectAppRegistrations | Bulk + per-app FIC | ~210 (for 200 apps) |
| CollectEntraServicePrincipals | Bulk only | ~3-5 |
| CollectDevices | Bulk only | ~3-5 |
| CollectRoleDefinitions | Bulk only | ~3 |
| CollectPolicies | Bulk only | ~10-15 |
| CollectAdministrativeUnits | Bulk + per-AU members | ~50-100 |
| CollectIntunePolicies | Bulk only | ~10-15 |
| CollectAzureResources | Per-subscription | ~10-50 |
| CollectAzureHierarchy | Per-subscription | ~5-10 |
| CollectEvents | Bulk (paginated) | ~5-20 |

---

## Table 1: Full Sync API Calls

*Note: CollectRoleDefinitions removed from solution*

| Collector | Small Tenant | Medium Tenant | Large Tenant | Primary Cost Driver |
|-----------|--------------|---------------|--------------|---------------------|
| | *(1K users, 100 groups, 200 apps, 300 SPs, 100 devices)* | *(10K users, 500 groups, 1K apps, 2K SPs, 1K devices)* | *(50K users, 2K groups, 5K apps, 10K SPs, 5K devices)* | |
| **CollectUsers** | 2,005 | 20,022 | 100,052 | 2 calls/user (auth methods) |
| **CollectRelationships** | 2,264 | 17,641 | 77,020 | licenses + owners + members |
| CollectEntraGroups | 6 | 10 | 20 | Bulk only |
| CollectAppRegistrations | 201 | 1,001 | 5,001 | 1 call/app (FIC) |
| CollectEntraServicePrincipals | 2 | 3 | 10 | Bulk only |
| CollectDevices | 2 | 2 | 5 | Bulk only |
| CollectPolicies | 15 | 20 | 30 | Bulk only |
| CollectAdministrativeUnits | 50 | 100 | 200 | members + scopedRoles |
| CollectIntunePolicies | 10 | 15 | 20 | Bulk only |
| CollectAzureResources | 20 | 50 | 100 | Per-subscription |
| CollectAzureHierarchy | 10 | 20 | 40 | Per-subscription |
| CollectEvents | 10 | 20 | 50 | Bulk (paginated) |
| **TOTAL** | **4,595** | **38,904** | **182,548** | |

---

## Table 2: Delta Sync API Calls (with Conditional Collection)

*Assumes: 1% of entities change between syncs, delta queries + conditional per-entity enrichment*

| Collector | Small Tenant | Medium Tenant | Large Tenant | Delta Strategy |
|-----------|--------------|---------------|--------------|----------------|
| | *(10 users, 1 group, 2 apps, 3 SPs, 1 device changed)* | *(100 users, 5 groups, 10 apps, 20 SPs, 10 devices changed)* | *(500 users, 20 groups, 50 apps, 100 SPs, 50 devices changed)* | |
| **CollectUsers** | 21 | 201 | 1,001 | delta list + auth for changed only |
| **CollectRelationships** | 65 | 215 | 870 | bulk calls + conditional per-entity |
| CollectEntraGroups | 1 | 1 | 1 | delta list only |
| CollectAppRegistrations | 3 | 11 | 51 | delta list + FIC for changed |
| CollectEntraServicePrincipals | 1 | 1 | 1 | delta list only |
| CollectDevices | 1 | 1 | 1 | delta list only |
| CollectPolicies | 0 | 0 | 0 | Skip (rarely changes) |
| CollectAdministrativeUnits | 5 | 10 | 30 | delta + conditional |
| CollectIntunePolicies | 0 | 0 | 0 | Skip (rarely changes) |
| CollectAzureResources | 0 | 0 | 0 | Skip (daily only) |
| CollectAzureHierarchy | 0 | 0 | 0 | Skip (daily only) |
| CollectEvents | 5 | 10 | 20 | Recent only |
| **TOTAL** | **102** | **450** | **1,975** | |

---

## Comparison Summary

| Metric | Small Tenant | Medium Tenant | Large Tenant |
|--------|--------------|---------------|--------------|
| **Full Sync** | 4,595 | 38,904 | 182,548 |
| **Delta Sync** | 102 | 450 | 1,975 |
| **Reduction** | **97.8%** | **98.8%** | **98.9%** |
| **Daily Total (1 Full + 3 Delta)** | 4,901 | 40,254 | 188,473 |
| **vs 4x Full** | 18,380 | 155,616 | 730,192 |
| **Daily Savings** | **73%** | **74%** | **74%** |

---

## Complete Delta Query Support Matrix (Research 2026-01-13)

### Microsoft Graph Resources with Delta Support (v1.0)

| Resource | Delta Endpoint | Our Collector | Impact |
|----------|----------------|---------------|--------|
| **user** | `/users/delta` | CollectUsers | ✅ Enables conditional auth method collection |
| **group** | `/groups/delta` | CollectEntraGroups | ✅ Enables conditional member collection |
| **application** | `/applications/delta` | CollectAppRegistrations | ✅ Enables conditional FIC/owner collection |
| **servicePrincipal** | `/servicePrincipals/delta` | CollectEntraServicePrincipals | ✅ Enables conditional owner collection |
| **device** | `/devices/delta` | CollectDevices | ✅ Enables conditional owner collection |
| **administrativeUnit** | `/directory/administrativeUnits/delta` | CollectAdministrativeUnits | ✅ Enables conditional member collection |
| **directoryRole** | `/directoryRoles/delta` | CollectRelationships | ✅ Role assignment tracking |
| **directoryObject** | `/directoryObjects/delta` | N/A (generic) | Can filter by type |
| **oAuth2PermissionGrant** | `/oauth2PermissionGrants/delta` | CollectRelationships | ✅ Consent tracking |
| **orgContact** | `/contacts/delta` | Not collected | N/A |

### Additional Delta-Supported Resources (Not Currently Collected)

| Resource | Delta Endpoint | Notes |
|----------|----------------|-------|
| callRecording | `/communications/callRecords/delta` | Teams recording |
| callTranscript | `/communications/callTranscripts/delta` | Teams transcript |
| chatMessage | `/teams/{id}/channels/{id}/messages/delta` | Teams messages |
| driveItem | `/drives/{id}/root/delta` | OneDrive/SharePoint |
| event | `/users/{id}/events/delta` | Calendar events |
| listItem | `/sites/{id}/lists/{id}/items/delta` | SharePoint lists |
| message | `/users/{id}/messages/delta` | Mail messages |
| site | `/sites/delta` | SharePoint sites |
| todoTask | `/me/todo/lists/{id}/tasks/delta` | To-do tasks |
| plannerUser | `/planner/buckets/delta` | Planner (beta) |

### Delta Token Expiration

| Resource Type | Token Expiration |
|---------------|------------------|
| Directory objects (user, group, app, SP, device, AU, directoryRole, orgContact, oauth2permissiongrant) | **7 days** |
| Outlook entities (message, event, contact) | Depends on internal cache |
| OneDrive/SharePoint (driveItem, listItem, site) | **30 days** |

**Source**: [Microsoft Graph Delta Query Overview](https://learn.microsoft.com/en-us/graph/delta-query-overview)

---

## Delta Query Reality Check

### What Delta CAN Help With

| Endpoint | Delta Support | Potential Savings |
|----------|---------------|-------------------|
| `/users` | ✅ Yes | Reduces user list calls from ~10 to ~1 |
| `/groups` | ✅ Yes | Reduces group list calls from ~1 to ~1 |
| `/applications` | ✅ Yes | Reduces app list calls from ~1 to ~1 |
| `/servicePrincipals` | ✅ Yes | Reduces SP list calls from ~2 to ~1 |
| `/devices` | ✅ Yes | Reduces device list calls from ~1 to ~1 |
| `/directoryRoles` | ✅ Yes | Minimal (already small) |
| `/administrativeUnits` | ✅ Yes | Enables conditional member collection |
| `/oauth2PermissionGrants` | ✅ Yes | Consent change tracking |

### What Delta CANNOT Help With (The Real Problem)

| Endpoint | Delta Support | Why It Matters |
|----------|---------------|----------------|
| `/users/{id}/authentication/methods` | ❌ No | **This is 50% of all API calls** |
| `/users/{id}/authentication/requirements` | ❌ No | **Combined with above = 50%+** |
| `/groups/{id}/members` | ✅ Yes (per-group) | Would need delta per group = complexity |
| `/users/{id}/licenseDetails` | ❌ No | 1 call per user |
| `/applications/{id}/owners` | ❌ No | 1 call per app |
| `/servicePrincipals/{id}/owners` | ❌ No | 1 call per SP |
| `/servicePrincipals/{id}/appRoleAssignedTo` | ❌ No | 1 call per SP |
| `/devices/{id}/registeredOwners` | ❌ No | 1 call per device |

### Honest Assessment

**The bulk of API calls come from per-entity enrichment, not from listing entities.**

For a 10,000 user tenant:
- `/users` list calls: ~10 (0.03% of total)
- `/users/{id}/authentication/*` calls: ~20,000 (54% of total)

**Delta would save ~10 calls out of ~36,800. That's 0.03% improvement.**

---

## Alternative Strategies (More Impactful)

### Strategy 1: Reduce Per-Entity Calls

| Approach | Impact | Feasibility |
|----------|--------|-------------|
| **Skip auth methods for disabled users** | Already implemented | ✅ Done |
| **Skip auth methods for guests** | Could save 10-30% | Medium |
| **Cache auth methods, refresh weekly** | Major savings | Complex |
| **Use $batch API** | Combine 20 calls into 1 | Medium |

### Strategy 2: $batch API for Per-Entity Calls

Microsoft Graph supports batching up to 20 requests per call:

```http
POST https://graph.microsoft.com/v1.0/$batch
{
  "requests": [
    { "id": "1", "method": "GET", "url": "/users/user1-id/authentication/methods" },
    { "id": "2", "method": "GET", "url": "/users/user2-id/authentication/methods" },
    ...up to 20 requests
  ]
}
```

**Potential impact**: Reduce 20,000 auth method calls to 1,000 batch calls (95% reduction).

### Strategy 3: Selective Collection

| Data | Current Frequency | Proposed | Rationale |
|------|-------------------|----------|-----------|
| Auth methods | Every run | Weekly full, skip delta | Users don't change auth methods daily |
| License details | Every run | Weekly | License changes are rare |
| Owners | Every run | Daily | Ownership changes are rare |
| Group members | Every run | Delta per group | Can use member delta |

### Strategy 4: Conditional Collection Based on Change Detection

```powershell
# Only fetch auth methods if user was modified recently
$changedUserIds = $deltaResponse.value | Where-Object { -not $_.'@removed' } | Select-Object -ExpandProperty id

foreach ($userId in $changedUserIds) {
    # Only these users get auth method calls
    $authMethods = Get-AuthMethods -UserId $userId
}
```

**Impact**: If 1% of users change daily, reduces auth calls from 10,000 to 100.

---

## Revised Implementation Recommendation

### Phase 1: $batch API Implementation (Highest Impact)

Implement batching for per-entity calls:

| Collector | Target Calls | Batching Impact |
|-----------|--------------|-----------------|
| CollectUsers | Auth methods/requirements | 20,000 → 2,000 (90% reduction) |
| CollectRelationships | License details | 10,000 → 500 (95% reduction) |
| CollectRelationships | App/SP owners | 3,000 → 150 (95% reduction) |

**Total potential reduction: 70-80% of API calls**

### Phase 2: Conditional Collection

Only fetch per-entity data for entities that changed:

| Data | Strategy |
|------|----------|
| Auth methods | Only for users modified in last 24h |
| Owners | Only for apps/SPs modified in last 24h |
| License details | Only for users with license changes |

**Total potential reduction: 90%+ for delta runs**

### Phase 3: Delta Queries (Lower Priority)

Add delta support for primary entity lists:
- `/users/delta`
- `/groups/delta`
- `/applications/delta`
- `/servicePrincipals/delta`
- `/devices/delta`

**Impact**: Minor (~1-2% additional savings) but enables Phase 2

---

## Data Hygiene (Already Implemented)

### Current Deletion Detection (Full Sync)

**The solution ALREADY detects deleted entities.** During each full sync, the indexer (`Invoke-DeltaIndexing` in [EntraDataCollection.psm1](../FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1#L1428)):

```powershell
# Check for deleted entities (lines 1428-1450)
foreach ($objectId in $existingEntities.Keys) {
    if (-not $currentEntities.ContainsKey($objectId)) {
        # DELETED entity - exists in Cosmos but NOT in Graph
        $deletedEntities += $existingEntities[$objectId]

        $changeLog += @{
            changeType = 'deleted'
            ...
        }
    }
}
```

**How it works:**
1. Indexer loads ALL existing entities from Cosmos via input binding
2. Collector sends ALL current entities from Graph to blob
3. Compare: If entity in Cosmos but NOT in Graph → **DELETED**
4. Entity gets soft-deleted: `deleted = true`, `effectiveTo = now`
5. Audit record created with `changeType = 'deleted'`

### Delta Implementation (Additional)

For delta syncs, process `@removed` markers from Graph delta response:

```powershell
foreach ($entity in $deltaResponse.value) {
    if ($entity.'@removed') {
        # Same soft-delete pattern as full sync
        $entity.deleted = $true
        $entity.effectiveTo = Get-Date -Format 'o'
    }
}
```

### No Wipe Required

Because the current architecture already handles deletions correctly:
- **Blob storage**: No wipe needed (each run creates new blobs)
- **Cosmos DB**: No wipe needed (existing deletion detection continues to work)
- **First delta run**: Falls back to full sync if no deltaLink exists

### Daily Full Sync Still Required

Even with delta, run daily full sync to:
1. Catch any missed changes (delta API edge cases)
2. Reset deltaLinks (they expire after ~30 days)
3. Ensure data consistency

---

## Recommended Schedule

| Time | Type | What Runs | Estimated API Calls |
|------|------|-----------|---------------------|
| 00:00 | **FULL** | All collectors, full data | ~4,500 (small) / ~37,000 (medium) |
| 06:00 | Delta | Changed entities only, skip auth methods | ~100-500 |
| 12:00 | Delta | Changed entities only, skip auth methods | ~100-500 |
| 18:00 | Delta | Changed entities only, skip auth methods | ~100-500 |

**With $batch + conditional collection**: Full sync could drop to ~1,500 (small) / ~5,000 (medium)

---

## Implementation Priority

| Priority | Change | Effort | Impact | Status |
|----------|--------|--------|--------|--------|
| **1** | $batch API for auth methods | Medium | **70%+ reduction in CollectUsers calls** | ✅ **VERIFIED** (94.4% reduction) |
| **2** | Delta queries for entity lists | Medium | Enables conditional collection | ✅ **VERIFIED** (2026-01-13) |
| **3** | Conditional auth method collection | Medium | **90%+ reduction in delta runs** | ✅ **VERIFIED** (2026-01-13) |
| **4** | Skip license details in delta | Low | 10-15% reduction | 🔲 Pending |

---

## Implementation Status (2026-01-13)

### Phase 1: $batch API - ✅ COMPLETE
- Added `Invoke-GraphBatch` function to [EntraDataCollection.psm1](../FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1#L307)
- Runtime verified: 826 individual calls → 46 batch calls = **94.4% reduction**
- Integrated in CollectRelationships and CollectUsers collectors

### Phase 2a: Delta Queries - ✅ COMPLETE
- Added delta query functions:
  - `Get-DeltaToken` - Retrieves stored delta token from blob storage
  - `Set-DeltaToken` - Stores delta token in blob storage
  - `Invoke-GraphDelta` - Executes delta query with automatic token management
- Delta tokens stored in `raw-data/delta-tokens/{resourceType}.json`
- Token expiration: 7 days (automatically falls back to full sync)
- Runtime verified in CollectDevices:
  - First run: Full sync (no stored token)
  - Second run: Incremental sync (used stored token)

### Phase 2b: Conditional Collection - 🔲 PENDING
- Use delta query results to only fetch per-entity data for changed entities
- Target collectors: CollectUsers (auth methods), CollectRelationships (owners, licenses)

---

## Summary

**Previous estimate (wrong)**: ~200 API calls per full sync
**Actual count**: ~4,500 (small) to ~185,000+ (large tenant)

**Delta queries alone won't help much** because the bottleneck is per-entity enrichment calls, not entity listing.

**Real optimization path**:
1. $batch API (biggest win)
2. Conditional collection (only fetch details for changed entities)
3. Delta queries (enables conditional collection)

---

## References

- [Microsoft Graph $batch API](https://learn.microsoft.com/en-us/graph/json-batching)
- [Microsoft Graph Delta Query](https://learn.microsoft.com/en-us/graph/delta-query-overview)
- [Graph API Throttling](https://learn.microsoft.com/en-us/graph/throttling)
