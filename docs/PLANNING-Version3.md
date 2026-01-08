# V3 Architecture Implementation Guide

> **Status:** Ready for Implementation
> **Date:** 2026-01-07
> **Prerequisite:** Read this document completely before making any changes

---

## Quick Reference

**This document enables a fresh Claude session (with codebase access) to implement V3.**

**Current State (V2.2):** 15 collectors (8 Entra + 7 Azure), Phase 1b properties added, AI Foundry present

**Target State (V3):** 6 unified containers, consolidated collectors, no AI Foundry

---

## Table of Contents

1. [Current V2 Architecture](#current-v2-architecture)
2. [V3 Goals](#v3-goals)
3. [Container Restructuring](#container-restructuring)
4. [Collector Consolidation](#collector-consolidation)
5. [Implementation Tasks](#implementation-tasks)
6. [File-by-File Changes](#file-by-file-changes)
7. [Cosmos DB Commands](#cosmos-db-commands)
8. [Validation Checklist](#validation-checklist)

---

## Current V2 Architecture

### V2.2 Collectors (15 total)

**Phase 1 - Entra Principals (5 collectors, parallel):**

| Collector | Output File | Discriminator |
|-----------|-------------|---------------|
| `CollectUsersWithAuthMethods` | `users.jsonl` | `principalType: "user"` |
| `CollectEntraGroups` | `groups.jsonl` | `principalType: "group"` |
| `CollectEntraServicePrincipals` | `serviceprincipals.jsonl` | `principalType: "servicePrincipal"` |
| `CollectDevices` | `devices.jsonl` | `principalType: "device"` |
| `CollectAppRegistrations` | `applications.jsonl` | `principalType: "application"` |

**Phase 2 - Relationships, Policies, Events (3 collectors, parallel):**

| Collector | Output File | Notes |
|-----------|-------------|-------|
| `CollectRelationships` | `relationships.jsonl` | 15 relationType values |
| `CollectPolicies` | `policies.jsonl` | 4 policyType values |
| `CollectEvents` | `events.jsonl` | signIn, audit |

**Phase 2.5 - Azure Resources (7 collectors, parallel):**

| Collector | Output Files | Status |
|-----------|--------------|--------|
| `CollectAzureHierarchy` | `azureresources.jsonl`, `azurerelationships.jsonl` | Existing |
| `CollectKeyVaults` | `keyvaults.jsonl`, `keyvault-relationships.jsonl` | Existing |
| `CollectVirtualMachines` | `virtualmachines.jsonl`, `vm-relationships.jsonl` | Existing |
| `CollectAutomationAccounts` | `automationaccounts.jsonl`, `automationaccount-relationships.jsonl` | **NEW - consolidation candidate** |
| `CollectFunctionApps` | `functionapps.jsonl`, `functionapp-relationships.jsonl` | **NEW - consolidation candidate** |
| `CollectLogicApps` | `logicapps.jsonl`, `logicapp-relationships.jsonl` | **NEW - consolidation candidate** |
| `CollectWebApps` | `webapps.jsonl`, `webapp-relationships.jsonl` | **NEW - consolidation candidate** |

**Phase 3 - Indexing (6 indexers):**
- `IndexPrincipalsInCosmosDB` (runs 5x for each principal type)
- `IndexRelationshipsInCosmosDB`
- `IndexPoliciesInCosmosDB`
- `IndexEventsInCosmosDB`
- `IndexAzureResourcesInCosmosDB` (runs 7x for each resource type)
- `IndexAzureRelationshipsInCosmosDB` (runs 7x for each resource type)

**Phase 4 - TestAIFoundry:** Optional connectivity test (TO BE REMOVED in V3)

### V2.2 Cosmos Containers (9 containers)

```
principals          /objectId       Users, Groups, SPs, Devices, Applications
relationships       /sourceId       Entra relationships only
azureResources      /resourceType   Azure resources
azureRelationships  /sourceId       Azure relationships only
policies            /policyType
events              /eventDate
changes             /changeDate
snapshots           /id
EntraData           (database)
```

### Phase 1b Fields Added (already implemented)

**Users:** mail, mailNickname, proxyAddresses, employeeId, employeeHireDate, employeeType, companyName, mobilePhone, businessPhones, department, jobTitle

**Groups:** expirationDateTime, renewedDateTime, resourceProvisioningOptions, resourceBehaviorOptions, preferredDataLocation, onPremisesSamAccountName, onPremisesLastSyncDateTime

**Service Principals:** appOwnerOrganizationId, preferredSingleSignOnMode, signInAudience, verifiedPublisher, homepage, loginUrl, logoutUrl, replyUrls

**Applications:** identifierUris, web, publicClient, spa, optionalClaims, groupMembershipClaims

**Devices:** extensionAttributes, mdmAppId, managementType, systemLabels

---

## V3 Goals

1. **Fix semantic errors:** Applications are resources, not principals
2. **Unify artificial separation:** Merge Entra/Azure relationships into single container
3. **Consolidate collectors:** 4 new Azure collectors merge into unified pattern
4. **Add temporal tracking:** `effectiveFrom`/`effectiveTo` for historical queries
5. **Enable Gremlin:** Design edges container for graph projection
6. **Remove AI Foundry:** Simplify architecture (defer to V4)
7. **Migrate to UnifiedRole APIs:** Replace DirectoryRole with roleManagement APIs

---

## Container Restructuring

### V2 (9 containers) → V3 (6 containers)

| V3 Container | Partition Key | Contains | From V2 |
|--------------|---------------|----------|---------|
| `principals` | `/principalType` | Users, Groups, SPs, Devices | principals (minus apps) |
| `resources` | `/resourceType` | Applications, ALL Azure resources | principals (apps only) + azureResources |
| `edges` | `/edgeType` | ALL relationships unified | relationships + azureRelationships |
| `policies` | `/policyType` | Unchanged | policies |
| `events` | `/eventDate` | Unchanged | events |
| `audit` | `/auditDate` | Changes + snapshots merged | changes + snapshots |

### Discriminator Changes

| V2 | V3 | Notes |
|----|-----|-------|
| `principalType` | `principalType` | **KEEP** - user, group, servicePrincipal, device (correct Microsoft Graph term) |
| `principalType: "application"` | `resourceType: "application"` | **MOVE** - Applications are resources, not principals |
| `relationType` | `edgeType` | **RENAME** - All 21+ relationship types unified |

**Rationale:** "Principal" is the correct Microsoft Graph terminology for entities that can be assigned permissions (users, groups, service principals, devices). "Identity" implies authentication capability, which doesn't accurately describe devices. Applications are resources that principals access, not principals themselves.

---

## Collector Consolidation

### V3 Collector Strategy

**Option A (Recommended): Consolidate Azure collectors**
- Keep 7 separate Azure collectors for parallel execution
- BUT have them all output to unified blobs:
  - `{timestamp}-resources.jsonl` (all Azure resources + applications)
  - `{timestamp}-edges.jsonl` (all relationships)

**Option B: Single mega-collector**
- One `CollectAzureResources` that handles all types
- Risk: Longer execution time, memory pressure

**Recommendation:** Option A - maintain parallelism but unify output format.

### Blob Structure Changes

**V2:**
```
raw-data/{timestamp}/
├── {timestamp}-users.jsonl
├── {timestamp}-groups.jsonl
├── {timestamp}-serviceprincipals.jsonl
├── {timestamp}-devices.jsonl
├── {timestamp}-applications.jsonl           ← Separate
├── {timestamp}-relationships.jsonl          ← Entra only
├── {timestamp}-azureresources.jsonl
├── {timestamp}-keyvaults.jsonl
├── {timestamp}-virtualmachines.jsonl
├── {timestamp}-automationaccounts.jsonl     ← NEW separate
├── {timestamp}-functionapps.jsonl           ← NEW separate
├── {timestamp}-logicapps.jsonl              ← NEW separate
├── {timestamp}-webapps.jsonl                ← NEW separate
├── {timestamp}-*-relationships.jsonl        ← Multiple Azure rel files
├── {timestamp}-policies.jsonl
└── {timestamp}-events.jsonl
```

**V3:**
```
raw-data/{timestamp}/
├── {timestamp}-principals.jsonl             ← Users, Groups, SPs, Devices (principalType discriminator)
├── {timestamp}-resources.jsonl              ← Apps + ALL Azure resources (resourceType discriminator)
├── {timestamp}-edges.jsonl                  ← ALL relationships unified (edgeType discriminator)
├── {timestamp}-policies.jsonl
└── {timestamp}-events.jsonl
```

---

## Implementation Tasks

### Task 1: Remove AI Foundry (FIRST)

**Files to delete:**
- `FunctionApp/TestAIFoundry/` (entire directory)

**Files to modify:**

1. `FunctionApp/Orchestrator/run.ps1`:
   - Remove Phase 4 section entirely
   - Remove `$aiTestResult` variable and references
   - Remove `AIFoundry` from final result object

2. `Infrastructure/main.bicep`:
   - Remove AI Foundry resource definitions
   - Remove AI-related parameters

3. `Infrastructure/deploy.ps1`:
   - Remove AI Foundry deployment logic

4. Documentation:
   - Remove AI Foundry references from README files

### Task 2: Update Discriminators

**In principal collectors (users, groups, SPs, devices):**
```powershell
# V2 and V3 - NO CHANGE
principalType = "user"        # Keep as-is
principalType = "group"       # Keep as-is
principalType = "servicePrincipal"  # Keep as-is
principalType = "device"      # Keep as-is
```

**In CollectAppRegistrations - MOVE to resources:**
```powershell
# V2
principalType = "application"

# V3
resourceType = "application"
```

**In all relationship collectors - RENAME discriminator:**
```powershell
# V2
relationType = "groupMember"

# V3
edgeType = "groupMember"
```

**Output file changes:**
- Principal collectors: output to `{timestamp}-principals.jsonl` (was separate files)
- CollectAppRegistrations: output to `{timestamp}-resources.jsonl`
- Relationship collectors: output to `{timestamp}-edges.jsonl`

### Task 3: Add Temporal Fields

**Add to all entities and edges:**
```powershell
effectiveFrom = $timestampFormatted  # When first seen
effectiveTo = $null                  # null = current, date = ended
```

**Update delta detection in `EntraDataCollection.psm1`:**
- On new entity: `effectiveFrom = now`
- On delete: `effectiveTo = now` (instead of `deleted = true`)
- Preserve `effectiveFrom` on updates

### Task 4: Consolidate Azure Collectors

**Each Azure collector should:**
1. Output to shared `{timestamp}-resources.jsonl` (append mode)
2. Output relationships to shared `{timestamp}-edges.jsonl` (append mode)
3. Use `resourceType` discriminator
4. Use `edgeType` discriminator for relationships

**Pattern for each collector:**
```powershell
$resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
$edgesBlobName = "$timestamp/$timestamp-edges.jsonl"
# Use Initialize-AppendBlob - it handles existing blobs
```

### Task 5: Consolidate Principal Collectors

**Each principal collector (users, groups, SPs, devices) should:**
1. Output to shared `{timestamp}-principals.jsonl` (append mode)
2. Keep `principalType` discriminator (correct Microsoft Graph term)
3. Add `effectiveFrom`/`effectiveTo` temporal fields

**Pattern for each collector:**
```powershell
$principalsBlobName = "$timestamp/$timestamp-principals.jsonl"
# Use Initialize-AppendBlob - it handles existing blobs
```

### Task 6: Unified Edges Collector

**Modify `CollectRelationships/run.ps1`:**
1. Change all `relationType` → `edgeType`
2. Output to `{timestamp}-edges.jsonl`
3. Add `effectiveFrom`/`effectiveTo` to all edges

**Edge ID format (keep consistent):**
```
{sourceId}_{targetId}_{edgeType}[_{qualifier}]
```

### Task 7: Create New Indexers

**New indexer structure:**
```
FunctionApp/
├── IndexPrincipalsInCosmosDB/       ← KEEP (but update for unified principals.jsonl)
│   ├── run.ps1
│   └── function.json
├── IndexResourcesInCosmosDB/        ← NEW (apps + Azure resources)
│   ├── run.ps1
│   └── function.json
└── IndexEdgesInCosmosDB/            ← NEW (replaces relationships + azureRelationships)
    ├── run.ps1
    └── function.json
```

**IndexerConfigs.psd1 changes:**
- Keep `principals` config (update for unified blob)
- Add `resources` config (apps + Azure)
- Rename `relationships` config → `edges`
- Remove `azureResources` and `azureRelationships` (merged into resources/edges)

### Task 8: Update Orchestrator

**New phase structure:**
```powershell
# Phase 1: ALL entities in parallel (14 collectors)
# - 4 principal collectors (users, groups, SPs, devices) → principals.jsonl
# - 8 resource collectors (apps + 7 Azure types) → resources.jsonl
# - Policies, Events collectors

# Phase 2: ALL relationships (unified edges collector) → edges.jsonl

# Phase 3: Unified indexing (5 indexers)
# - IndexPrincipalsInCosmosDB → principals container
# - IndexResourcesInCosmosDB → resources container
# - IndexEdgesInCosmosDB → edges container
# - IndexPoliciesInCosmosDB → policies container
# - IndexEventsInCosmosDB → events container
```

---

## File-by-File Changes

### HIGH PRIORITY

| File | Action | Details |
|------|--------|---------|
| `FunctionApp/TestAIFoundry/` | DELETE | Remove entire directory |
| `FunctionApp/Orchestrator/run.ps1` | MODIFY | Remove AI Foundry, reorder phases, update collector list |
| `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` | MODIFY | Add temporal fields, merge Azure configs into resources/edges |
| `FunctionApp/CollectAppRegistrations/run.ps1` | MODIFY | `principalType` → `resourceType`, output to resources.jsonl |
| `FunctionApp/CollectRelationships/run.ps1` | MODIFY | `relationType` → `edgeType`, output to edges.jsonl, add temporal fields |

### MEDIUM PRIORITY

| File | Action | Details |
|------|--------|---------|
| `FunctionApp/CollectUsersWithAuthMethods/run.ps1` | MODIFY | Keep `principalType`, output to principals.jsonl, add temporal fields |
| `FunctionApp/CollectEntraGroups/run.ps1` | MODIFY | Keep `principalType`, output to principals.jsonl, add temporal fields |
| `FunctionApp/CollectEntraServicePrincipals/run.ps1` | MODIFY | Keep `principalType`, output to principals.jsonl, add temporal fields |
| `FunctionApp/CollectDevices/run.ps1` | MODIFY | Keep `principalType`, output to principals.jsonl, add temporal fields |
| `FunctionApp/CollectAzureHierarchy/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectKeyVaults/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectVirtualMachines/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectAutomationAccounts/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectFunctionApps/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectLogicApps/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |
| `FunctionApp/CollectWebApps/run.ps1` | MODIFY | Output to unified resources.jsonl/edges.jsonl |

### NEW FILES TO CREATE

| File | Action | Details |
|------|--------|---------|
| `FunctionApp/IndexResourcesInCosmosDB/run.ps1` | CREATE | New indexer for resources container (apps + Azure) |
| `FunctionApp/IndexResourcesInCosmosDB/function.json` | CREATE | Bindings for resources indexer |
| `FunctionApp/IndexEdgesInCosmosDB/run.ps1` | CREATE | New indexer for edges container (all relationships) |
| `FunctionApp/IndexEdgesInCosmosDB/function.json` | CREATE | Bindings for edges indexer |

### MODIFY (update for V3)

| File | Action | Details |
|------|--------|---------|
| `FunctionApp/IndexPrincipalsInCosmosDB/` | MODIFY | Update for unified principals.jsonl input |

### DELETE (after V3 validated)

| File | Action | Details |
|------|--------|---------|
| `FunctionApp/IndexRelationshipsInCosmosDB/` | DELETE | Replaced by IndexEdgesInCosmosDB |
| `FunctionApp/IndexAzureResourcesInCosmosDB/` | DELETE | Merged into IndexResourcesInCosmosDB |
| `FunctionApp/IndexAzureRelationshipsInCosmosDB/` | DELETE | Merged into IndexEdgesInCosmosDB |

---

## Cosmos DB Commands

### Create V3 Containers

```bash
# Set variables (update these for your environment)
RG="rg-entrarisk-pilot-001"
ACCOUNT="cosno-entrarisk-dev-xxxxx"
DB="EntraData"

# NOTE: principals container already exists from V2 - just reuse it
# Only need to create: resources, edges, audit

az cosmosdb sql container create \
  --account-name $ACCOUNT \
  --database-name $DB \
  --resource-group $RG \
  --name resources \
  --partition-key-path /resourceType

az cosmosdb sql container create \
  --account-name $ACCOUNT \
  --database-name $DB \
  --resource-group $RG \
  --name edges \
  --partition-key-path /edgeType

az cosmosdb sql container create \
  --account-name $ACCOUNT \
  --database-name $DB \
  --resource-group $RG \
  --name audit \
  --partition-key-path /auditDate
```

### Delete V2 Containers (AFTER validation)

```bash
# Only run after V3 is fully validated!
# NOTE: Keep principals container - it's used in V3 (just updated for unified blob)
az cosmosdb sql container delete --account-name $ACCOUNT --database-name $DB --resource-group $RG --name relationships --yes
az cosmosdb sql container delete --account-name $ACCOUNT --database-name $DB --resource-group $RG --name azureResources --yes
az cosmosdb sql container delete --account-name $ACCOUNT --database-name $DB --resource-group $RG --name azureRelationships --yes
az cosmosdb sql container delete --account-name $ACCOUNT --database-name $DB --resource-group $RG --name changes --yes
az cosmosdb sql container delete --account-name $ACCOUNT --database-name $DB --resource-group $RG --name snapshots --yes
```

---

## Validation Checklist

### Pre-Implementation
- [ ] Read this entire document
- [ ] Verify current collector count matches (15 collectors)
- [ ] Verify IndexerConfigs.psd1 has Phase 1b and Phase 3 fields

### Task 1: AI Foundry Removal
- [ ] Delete `FunctionApp/TestAIFoundry/` directory
- [ ] Remove Phase 4 from `Orchestrator/run.ps1`
- [ ] Remove AI Foundry from Bicep templates (if present)
- [ ] Deploy and verify orchestration completes without AI Foundry

### Task 2: Discriminator Updates
- [ ] Principal collectors keep `principalType` (users, groups, SPs, devices)
- [ ] CollectAppRegistrations uses `resourceType` (moved to resources)
- [ ] All relationship output uses `edgeType` (renamed from relationType)
- [ ] IndexerConfigs.psd1 updated

### Task 3: Temporal Fields
- [ ] `effectiveFrom` added to all entities
- [ ] `effectiveTo` added to all entities
- [ ] Delta detection preserves `effectiveFrom` on updates

### Task 4: Blob Consolidation
- [ ] All principal collectors output to `principals.jsonl`
- [ ] All resource collectors output to `resources.jsonl`
- [ ] All relationship collectors output to `edges.jsonl`
- [ ] Append mode works correctly (no overwrites)

### Task 5: Cosmos Containers
- [ ] V3 containers created (resources, edges, audit - principals already exists)
- [ ] V3 indexers deployed and working
- [ ] Data indexed correctly
- [ ] Queries return expected results

### Task 6: Cleanup
- [ ] V2 indexers removed from codebase (IndexRelationshipsInCosmosDB, IndexAzureResourcesInCosmosDB, IndexAzureRelationshipsInCosmosDB)
- [ ] V2 containers deleted from Cosmos (relationships, azureResources, azureRelationships, changes, snapshots)
- [ ] Documentation updated

---

## Edge Types Reference (21+ types)

### Entra Edges (15 types)

| edgeType | Source | Target |
|----------|--------|--------|
| groupMember | principal | group |
| groupMemberTransitive | principal | group |
| directoryRole | principal | directoryRole |
| pimEligible | principal | directoryRole |
| pimActive | principal | directoryRole |
| pimGroupEligible | principal | group |
| pimGroupActive | principal | group |
| appOwner | principal | application |
| spOwner | principal | servicePrincipal |
| groupOwner | principal | group |
| deviceOwner | principal | device |
| license | user | license |
| oauth2PermissionGrant | principal/tenant | servicePrincipal |
| appRoleAssignment | principal | servicePrincipal |
| azureRbac | principal | azureRole |

### Azure Edges (6 types)

| edgeType | Source | Target |
|----------|--------|--------|
| contains | resource | resource |
| keyVaultAccess | principal | keyVault |
| hasManagedIdentity | resource | servicePrincipal |
| spToApplication | servicePrincipal | application |
| tenantContains | tenant | managementGroup/subscription |
| resourceGroupContains | resourceGroup | resource |

---

## Questions Already Resolved

| Question | Answer |
|----------|--------|
| V3 goal? | All: cleanliness + performance + capabilities |
| Breaking changes OK? | Yes, full rebuild from blobs acceptable |
| Where do Applications go? | Resources container (correct semantics) |
| Gremlin in V3 scope? | Yes, design edges container for Gremlin projection |
| UnifiedRole APIs? | Yes, migrate from DirectoryRole to roleManagement APIs |
| AI Foundry? | Remove in V3, defer to V4 |
| Keep separate Azure collectors? | Yes for parallelism, but output to unified blobs |

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

---

## Gremlin Design Considerations

**The unified `edges` container is Gremlin-ready by design:**

1. **Consistent edge format:** `{sourceId}_{targetId}_{edgeType}` maps directly to Gremlin edges
2. **Type discriminator as label:** `edgeType` becomes Gremlin edge label
3. **Minimal projection:** Gremlin only needs id, sourceId, targetId, edgeType

**Gremlin Projection (Future Phase):**
```
After V3 indexing completes:
  1. Read from principals → Gremlin vertices (label = principalType)
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

**End of V3 Implementation Guide**
