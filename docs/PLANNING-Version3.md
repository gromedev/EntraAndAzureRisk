# V3 Architecture Redesign

> **Status:** Draft
> **Date:** 2026-01-07
> **Goal:** Architectural cleanliness + Query performance + Attack path analysis + Gremlin-ready

---

## Executive Summary

V3 addresses fundamental design issues in V2:
1. **Application as principal** - semantically wrong (applications are resources, not identities)
2. **Entra/Azure separation** - artificial (they're interconnected via RBAC, managed identities)
3. **Orchestration ordering** - Azure should be Phase 1 so relationships process together
4. **No temporal tracking** - can't query "who had access on date X?"
5. **DirectoryRole APIs** - migrate to Microsoft's recommended UnifiedRoleAssignment APIs
6. **Gremlin integration** - design with graph projection in mind from day 1

**Breaking changes OK** - full rebuild from blobs is acceptable.

---

## Container Structure: V2 → V3

### V2 (8 containers)
```
principals          /objectId       Users, Groups, SPs, Devices, Applications ← WRONG
relationships       /sourceId       Entra relationships only
azureResources      /resourceType   Azure resources
azureRelationships  /sourceId       Azure relationships only ← ARTIFICIAL SEPARATION
policies            /policyType
events              /eventDate
changes             /changeDate
snapshots           /id
```

### V3 (6 containers)
```
identities    /identityType   Users, Groups, SPs, Devices (things that authenticate)
resources     /resourceType   Applications, Azure resources (things that are accessed)
edges         /edgeType       ALL relationships unified (21+ types)
policies      /policyType     Unchanged
events        /eventDate      Unchanged
audit         /auditDate      Changes + snapshots merged
```

---

## Key Changes

### 1. Applications Move to Resources

**Before (wrong):**
```json
{ "objectId": "...", "principalType": "application" }  // In principals container
```

**After (correct):**
```json
{ "objectId": "...", "resourceType": "application" }   // In resources container
```

Applications are resource definitions. Service Principals are the runtime identities.

### 2. Unified Relationships Container

**Before:** Separate `relationships` and `azureRelationships` containers.

**After:** Single `edges` container with ALL relationship types:
- Entra: groupMember, directoryRole, pimEligible, appOwner, etc. (14 types)
- Azure: contains, keyVaultAccess, hasManagedIdentity (3 types)
- Cross-domain: azureRbac, spToApplication (existing but unified)

### 3. Reordered Orchestration

**Before:**
```
Phase 1:   Entra entities (5 collectors)
Phase 2:   Entra relationships, policies, events
Phase 2.5: Azure entities + relationships  ← TOO LATE
Phase 3:   Index
```

**After:**
```
Phase 1: ALL entities in parallel (11 collectors)
         - Entra identities: Users, Groups, SPs, Devices
         - Resources: Applications, Azure hierarchy, KeyVaults, VMs
         - Policies, Events

Phase 2: ALL relationships (single mega-collector)
         - Can resolve cross-domain references
         - Can create SP→Application edges

Phase 3: Index to unified containers
```

### 4. Temporal Tracking

**New fields on all entities and edges:**
```json
{
  "effectiveFrom": "2026-01-07T00:00:00Z",  // When relationship started
  "effectiveTo": null                        // null = current, date = ended
}
```

Enables: "Who had Global Admin access on December 1st?"

### 5. Partition Key Optimization

| Container | V2 Key | V3 Key | Benefit |
|-----------|--------|--------|---------|
| identities | /objectId | /identityType | Filter by user/group/SP efficiently |
| resources | /resourceType | /resourceType | Same (good choice) |
| edges | /sourceId | /edgeType | Filter by relationship type efficiently |

**For "who can access X?" queries:** Use composite index on targetId.

---

## Discriminator Changes

| Container | V2 Discriminator | V3 Discriminator | Values |
|-----------|------------------|------------------|--------|
| identities | principalType | identityType | user, group, servicePrincipal, device |
| resources | resourceType | resourceType | application, tenant, managementGroup, subscription, resourceGroup, keyVault, virtualMachine |
| edges | relationType | edgeType | groupMember, directoryRole, pimEligible, azureRbac, contains, keyVaultAccess, etc. |

---

## Implementation Checklist

### Collector Changes

| Collector | Change |
|-----------|--------|
| CollectUsersWithAuthMethods | `principalType` → `identityType: "user"` |
| CollectEntraGroups | `principalType` → `identityType: "group"` |
| CollectEntraServicePrincipals | `principalType` → `identityType: "servicePrincipal"` |
| CollectDevices | `principalType` → `identityType: "device"` |
| **CollectAppRegistrations** | **Move to resources blob**, `principalType` → `resourceType: "application"` |
| CollectAzureHierarchy | Move to **Phase 1**, output to resources blob |
| CollectKeyVaults | Move to **Phase 1**, output to resources blob |
| CollectVirtualMachines | Move to **Phase 1**, output to resources blob |
| **CollectRelationships** | Unify Entra + Azure edges, `relationType` → `edgeType` |

### New/Modified Files

```
FunctionApp/
├── Orchestrator/run.ps1                    # Reorder phases
├── Modules/EntraDataCollection/
│   ├── IndexerConfigs.psd1                 # New identities, resources, edges configs
│   └── EntraDataCollection.psm1            # Update delta detection for temporal fields
├── CollectAppRegistrations/run.ps1         # Output resourceType, resources blob
├── CollectRelationships/run.ps1            # Mega-collector for ALL edges
├── IndexIdentities/                        # New indexer
│   ├── run.ps1
│   └── function.json
├── IndexResources/                         # New indexer (apps + Azure)
│   ├── run.ps1
│   └── function.json
└── IndexEdges/                             # New unified indexer
    ├── run.ps1
    └── function.json
```

### Cosmos Container Creation

```bash
# Create new V3 containers
az cosmosdb sql container create --name identities --partition-key-path /identityType
az cosmosdb sql container create --name resources --partition-key-path /resourceType
az cosmosdb sql container create --name edges --partition-key-path /edgeType
az cosmosdb sql container create --name audit --partition-key-path /auditDate

# After validation, drop V2 containers
az cosmosdb sql container delete --name principals
az cosmosdb sql container delete --name relationships
az cosmosdb sql container delete --name azureResources
az cosmosdb sql container delete --name azureRelationships
az cosmosdb sql container delete --name changes
az cosmosdb sql container delete --name snapshots
```

---

## Edge ID Format (Consistent)

All edges use: `{sourceId}_{targetId}_{edgeType}[_{qualifier}]`

```
user123_group456_groupMember
user123_group789_groupMemberTransitive
user123_role-def-id_pimEligible
sp123_app456_spToApplication           ← NEW: Link SP to its App
/subscriptions/xxx_/subscriptions/xxx/resourceGroups/yyy_contains
user123_kv-arm-id_keyVaultAccess
```

---

## Blob Structure Changes

**V2:**
```
raw-data/{timestamp}/
├── {timestamp}-users.jsonl
├── {timestamp}-groups.jsonl
├── {timestamp}-serviceprincipals.jsonl
├── {timestamp}-devices.jsonl
├── {timestamp}-applications.jsonl         ← Principals blob
├── {timestamp}-relationships.jsonl        ← Entra only
├── {timestamp}-azureresources.jsonl
├── {timestamp}-azurerelationships.jsonl   ← Separate!
├── {timestamp}-policies.jsonl
└── {timestamp}-events.jsonl
```

**V3:**
```
raw-data/{timestamp}/
├── {timestamp}-identities.jsonl           ← Users, Groups, SPs, Devices
├── {timestamp}-resources.jsonl            ← Apps + ALL Azure resources
├── {timestamp}-edges.jsonl                ← ALL relationships unified
├── {timestamp}-policies.jsonl
└── {timestamp}-events.jsonl
```

---

## Migration Strategy

1. **Create V3 containers** (parallel to V2)
2. **Update collectors** to output V3 format
3. **Create V3 indexers** writing to new containers
4. **Run V2 + V3 indexers** in parallel for validation
5. **Update Dashboard** to read V3 containers
6. **Drop V2 containers** after validation

---

## Critical Files to Modify

| File | Priority | Changes |
|------|----------|---------|
| `FunctionApp/Orchestrator/run.ps1` | HIGH | Reorder phases, move Azure to Phase 1 |
| `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` | HIGH | New identities, resources, edges configs |
| `FunctionApp/CollectAppRegistrations/run.ps1` | HIGH | resourceType discriminator, resources blob |
| `FunctionApp/CollectRelationships/run.ps1` | HIGH | Unify all edges, add temporal fields |
| `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1` | MEDIUM | Temporal tracking in delta detection |
| All Azure collectors | MEDIUM | Move to Phase 1, output to resources blob |

---

## Questions Resolved

| Question | Answer |
|----------|--------|
| V3 goal? | All: cleanliness + performance + capabilities |
| Breaking changes OK? | Yes, full rebuild from blobs |
| Where do Applications go? | Resources container (correct semantics) |
| Gremlin in V3? | Yes, design edges container for Gremlin projection from day 1 |
| UnifiedRole APIs? | Yes, migrate from DirectoryRole to UnifiedRoleAssignment APIs |

---

## UnifiedRole API Migration

**Current (V2):**
- `/directoryRoles?$expand=members` - legacy enumeration
- `/roleManagement/directory/roleEligibilitySchedules` - PIM eligible
- `/roleManagement/directory/roleAssignmentSchedules` - PIM active

**V3 (Unified):**
- `/roleManagement/directory/roleDefinitions` - all role definitions
- `/roleManagement/directory/roleAssignments` - all assignments (replaces directoryRoles)
- `/roleManagement/directory/roleEligibilitySchedules` - PIM eligible (unchanged)
- `/roleManagement/directory/roleAssignmentSchedules` - PIM active (unchanged)

**Benefits:**
- Consistent API surface
- Includes custom roles (not just built-in)
- Better alignment with Azure RBAC patterns
- Scoped role assignments (AU-scoped)

**Edge type impact:**
```
directoryRole     → roleAssignment (unified)
pimEligible       → roleEligible (renamed for consistency)
pimActive         → roleActive (renamed for consistency)
```

---

## Gremlin Design Considerations

**The unified `edges` container is Gremlin-ready by design:**

1. **Consistent edge format:** `{sourceId}_{targetId}_{edgeType}` maps directly to Gremlin edges
2. **Type discriminator as label:** `edgeType` becomes Gremlin edge label
3. **Minimal projection:** Gremlin only needs id, sourceId, targetId, edgeType

**Gremlin Projection (Phase 4):**
```
After V3 indexing completes:
  1. Read from identities → Gremlin vertices (label = identityType)
  2. Read from resources → Gremlin vertices (label = resourceType)
  3. Read from edges → Gremlin edges (label = edgeType)
```

**Attack path queries enabled:**
```gremlin
// "Who can reach Global Admin?"
g.V().hasLabel('directoryRole').has('roleTemplateId', 'global-admin-id')
  .repeat(__.in()).emit().path()

// "What can this compromised user access?"
g.V('user-id').repeat(out()).emit().path()

// "Attack path: User → Group → VM → Managed Identity → KeyVault"
g.V('user-id').out('groupMember').out('azureRbac').out('hasManagedIdentity').out('keyVaultAccess')
```

---

## Next Steps

1. Review this plan
2. Approve or request changes
3. Begin implementation (Orchestrator first, then collectors, then indexers)

---

**End of V3 Architecture Plan**
