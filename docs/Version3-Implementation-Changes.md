# V3 Implementation Changelog

> **Status:** In Progress
> **Started:** 2026-01-08
> **Branch:** experimental-version3

---

## Summary

V3 restructures the data model for semantic correctness and unified containers:
- **Principals** (users, groups, SPs, devices) → `principals` container with `principalType` discriminator
- **Resources** (applications, Azure resources) → `resources` container with `resourceType` discriminator
- **Edges** (all relationships) → `edges` container with `edgeType` discriminator

---

## Completed Changes

### 1. AI Foundry Removal
- [x] Deleted `FunctionApp/TestAIFoundry/` directory
- [x] Removed Phase 4 from Orchestrator

### 2. Planning Document Updated
- [x] Updated `docs/PLANNING-Version3.md` with correct terminology
- [x] Changed `identityType` → `principalType` (Microsoft Graph correct term)
- [x] Documented rationale for terminology choices
- [x] Updated all references throughout the document

### 3. Principal Collectors Updated

#### CollectUsersWithAuthMethods/run.ps1
- [x] Keep `principalType = "user"` (no change to discriminator)
- [x] Output to `{timestamp}-principals.jsonl` (was `users.jsonl`)
- [x] Added `effectiveFrom` temporal field
- [x] Added `effectiveTo` temporal field (null = current)
- [x] Return property: `PrincipalsBlobName`

#### CollectEntraGroups/run.ps1
- [x] Keep `principalType = "group"` (no change to discriminator)
- [x] Output to `{timestamp}-principals.jsonl` (was `groups.jsonl`)
- [x] Added `effectiveFrom` temporal field
- [x] Added `effectiveTo` temporal field
- [x] Return property: `PrincipalsBlobName`

#### CollectEntraServicePrincipals/run.ps1
- [x] Keep `principalType = "servicePrincipal"` (no change to discriminator)
- [x] Output to `{timestamp}-principals.jsonl` (was `serviceprincipals.jsonl`)
- [x] Added `effectiveFrom` temporal field
- [x] Added `effectiveTo` temporal field
- [x] Return property: `PrincipalsBlobName`
- [x] Updated synopsis for V3 architecture

#### CollectDevices/run.ps1
- [x] Keep `principalType = "device"` (no change to discriminator)
- [x] Output to `{timestamp}-principals.jsonl` (was `devices.jsonl`)
- [x] Added `effectiveFrom` temporal field
- [x] Added `effectiveTo` temporal field
- [x] Return property: `PrincipalsBlobName`
- [x] Updated synopsis for V3 architecture

### 4. Resource Collectors Updated

#### CollectAppRegistrations/run.ps1
- [x] Changed `principalType = "application"` → `resourceType = "application"`
- [x] Output to `{timestamp}-resources.jsonl` (was `appregistrations.jsonl`)
- [x] Added `effectiveFrom` temporal field
- [x] Added `effectiveTo` temporal field
- [x] Return property: `ResourcesBlobName`
- [x] Updated synopsis for V3 architecture

### 5. Edge Collector Updated

#### CollectRelationships/run.ps1
- [x] Changed `relationType` → `edgeType` throughout (all 14+ relationship types)
- [x] Output to `{timestamp}-edges.jsonl` (was `relationships.jsonl`)
- [x] Return property: `EdgesBlobName`
- [x] Updated synopsis for V3 architecture

### 6. Orchestrator Fully Updated
- [x] Updated `FunctionApp/Orchestrator/run.ps1` for V3 architecture
- [x] Changed all `IdentitiesBlobName` references to `PrincipalsBlobName`
- [x] Changed `identitiesIndexResult` to `principalsIndexResult`
- [x] Changed `IndexIdentitiesInCosmosDB` to `IndexPrincipalsInCosmosDB`
- [x] Updated all Summary fields: `TotalIdentities` → `TotalPrincipals`
- [x] Updated edges references from `BlobName` to `EdgesBlobName`
- [x] Updated phase comments: "Principal Collectors" instead of "Identity Collectors"
- [x] Updated indexing section for principals terminology

### 7. Indexers Updated (V3 Architecture)
- [x] Renamed `IndexRelationshipsInCosmosDB` → `IndexEdgesInCosmosDB`
  - Updated run.ps1 for `edges` entity type
  - Updated function.json to use `edges` container with `/edgeType` partition
  - Changed binding names to `edgesRawOut`, `edgeChangesOut`, `edgesRawIn`
- [x] Renamed `IndexAzureResourcesInCosmosDB` → `IndexResourcesInCosmosDB`
  - Updated run.ps1 for `resources` entity type
  - Updated function.json to use `resources` container with `/resourceType` partition
  - Changed binding names to `resourcesRawOut`, `resourceChangesOut`, `resourcesRawIn`
- [x] Deleted orphaned `IndexAzureRelationshipsInCosmosDB` (not called by Orchestrator)
- [x] Updated `IndexerConfigs.psd1`:
  - Renamed `relationships` → `edges` with `edgeType` discriminator
  - Renamed `azureResources` → `resources`
  - Updated all binding names for V3 containers

### 8. Code Review Completed
- [x] PSScriptAnalyzer analysis - all clean (only expected warnings)
- [x] Git diff comparison with V2 - identified orphaned indexers
- [x] Removed unused/orphaned code

### 9. Azure Resource Collectors Updated
- [x] `CollectAzureHierarchy/run.ps1` - output to resources.jsonl/edges.jsonl
  - Blob names: `azureresources.jsonl` → `resources.jsonl`, `relationships.jsonl` → `edges.jsonl`
  - Variables: `$relationshipsJsonL` → `$edgesJsonL`
  - Discriminator: `relationType` → `edgeType`
  - Temporal fields: `effectiveFrom`, `effectiveTo` added
  - Return property: `RelationshipsBlobName` → `EdgesBlobName`
- [x] `CollectKeyVaults/run.ps1` - output to resources.jsonl/edges.jsonl
- [x] `CollectVirtualMachines/run.ps1` - output to resources.jsonl/edges.jsonl
- [x] `CollectAutomationAccounts/run.ps1` - output to resources.jsonl/edges.jsonl
- [x] `CollectFunctionApps/run.ps1` - output to resources.jsonl/edges.jsonl
- [x] `CollectLogicApps/run.ps1` - output to resources.jsonl/edges.jsonl
- [x] `CollectWebApps/run.ps1` - output to resources.jsonl/edges.jsonl

### 10. Indexer Function.json Updates
- [x] All indexers now use `audit` container for change tracking
  - `IndexPrincipalsInCosmosDB/function.json` - principalChangesOut → audit container
  - `IndexResourcesInCosmosDB/function.json` - resourceChangesOut → audit container
  - `IndexEdgesInCosmosDB/function.json` - edgeChangesOut → audit container
  - `IndexPoliciesInCosmosDB/function.json` - policyChangesOut → audit container

### 11. Delta Detection Temporal Fields (V3)
- [x] Updated `EntraDataCollection.psm1` delta detection logic
  - On delete: `effectiveTo = now` (instead of just `deleted = true`)
  - Preserved backward compatibility: `deleted = true` still set during transition
  - On current entities: `effectiveTo = null`
  - `effectiveFrom` preserved from entity or set to now if missing

---

## Pending Changes

None - V3 core implementation complete!

---

## File Changes Summary

| File | Status | Change Type |
|------|--------|-------------|
| `FunctionApp/TestAIFoundry/` | DELETED | Removed |
| `docs/PLANNING-Version3.md` | UPDATED | Terminology fixes |
| `FunctionApp/Orchestrator/run.ps1` | UPDATED | V3 architecture, principals terminology |
| `FunctionApp/CollectUsersWithAuthMethods/run.ps1` | UPDATED | principals.jsonl, temporal fields |
| `FunctionApp/CollectEntraGroups/run.ps1` | UPDATED | principals.jsonl, temporal fields |
| `FunctionApp/CollectEntraServicePrincipals/run.ps1` | UPDATED | principals.jsonl, temporal fields |
| `FunctionApp/CollectDevices/run.ps1` | UPDATED | principals.jsonl, temporal fields |
| `FunctionApp/CollectAppRegistrations/run.ps1` | UPDATED | resourceType, resources.jsonl |
| `FunctionApp/CollectRelationships/run.ps1` | UPDATED | edgeType, edges.jsonl |
| `FunctionApp/IndexRelationshipsInCosmosDB/` | RENAMED | → `IndexEdgesInCosmosDB` |
| `FunctionApp/IndexAzureResourcesInCosmosDB/` | RENAMED | → `IndexResourcesInCosmosDB` |
| `FunctionApp/IndexAzureRelationshipsInCosmosDB/` | DELETED | Orphaned, not called |
| `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` | UPDATED | V3 entity types |
| `FunctionApp/CollectAzureHierarchy/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, temporal fields |
| `FunctionApp/CollectKeyVaults/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/CollectVirtualMachines/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/CollectAutomationAccounts/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/CollectFunctionApps/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/CollectLogicApps/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/CollectWebApps/run.ps1` | UPDATED | resources.jsonl/edges.jsonl, edgeType |
| `FunctionApp/IndexPrincipalsInCosmosDB/function.json` | UPDATED | audit container binding |
| `FunctionApp/IndexResourcesInCosmosDB/function.json` | UPDATED | audit container binding |
| `FunctionApp/IndexEdgesInCosmosDB/function.json` | UPDATED | audit container binding |
| `FunctionApp/IndexPoliciesInCosmosDB/function.json` | UPDATED | audit container binding |
| `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1` | UPDATED | V3 temporal fields in delta detection |

---

## Key Terminology Decisions

| Term | Usage | Rationale |
|------|-------|-----------|
| `principalType` | users, groups, SPs, devices | Correct Microsoft Graph term for entities that can be assigned permissions |
| `resourceType` | applications, Azure resources | Applications are resources that principals access, not principals themselves |
| `edgeType` | all relationships | Unified discriminator for graph edges (renamed from `relationType`) |

---

## Testing Notes

After completing V3 implementation:
1. Deploy to separate resource group
2. Run full orchestration
3. Verify blob outputs: `principals.jsonl`, `resources.jsonl`, `edges.jsonl`
4. Verify Cosmos DB indexing
5. Test Power BI connectivity
6. Validate Gremlin projection capability

---

## Rollback

If needed, revert to `main` branch - all V3 changes are on `experimental-version3` branch.
