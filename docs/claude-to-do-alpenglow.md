# Alpenglow Alpha Migration To-Do List

## Overview
Migrating EntraAndAzureRisk (v3.5) to Alpenglow Alpha with separate Function Apps for security isolation.

## Design Decisions (Confirmed)
- **Naming suffix**: Keep `uniqueString()` for globally unique names
- **App Service Plan**: Shared consumption (Y1) plan for both function apps
- **Security isolation**: Separate managed identities (not separate plans)
- **Dashboard route**: Keep `/api/dashboard` path

---

## Phase 0: Remove Unimplemented Resource Types

### 0.1 Disable VMSS and Data Factory Collection
These resource types are not ready for production. Remove from collection but keep Dashboard tabs as placeholders.

- [ ] Remove `vmScaleSet` entry from `FunctionApp/Modules/EntraDataCollection/AzureResourceTypes.psd1` (lines 41-46)
- [ ] Remove `dataFactory` entry from `FunctionApp/Modules/EntraDataCollection/AzureResourceTypes.psd1` (lines 47-53)
- [ ] Update Dashboard VMSS tab to show placeholder message: "Placeholder only. Feature not implemented yet"
- [ ] Update Dashboard Data Factory tab to show placeholder message: "Placeholder only. Feature not implemented yet"

**Note:** The switch cases in `CollectAzureResources/run.ps1` can remain as dead code - they won't execute without the config entries and can be re-enabled later.

---

## Phase 1: Project Structure Changes

### 1.1 Separate Dashboard into its own Function App
- [ ] Create `/FunctionApp-www/` directory structure
  - [ ] Create `host.json` (minimal - no DurableTask needed)
  - [ ] Create `profile.ps1` (simplified - no module loading needed)
  - [ ] Create `requirements.psd1`
  - [ ] Copy `Dashboard/` function to `/FunctionApp-www/Dashboard/`
  - [ ] Update Dashboard branding to "Alpenglow Dashboard (Alpha)"
  - [ ] The www function app does NOT need Modules/ (Dashboard uses Cosmos bindings only)

### 1.2 Rename FunctionApp to FunctionApp-Data
- [ ] Rename `/FunctionApp/` to `/FunctionApp-Data/`
- [ ] Remove Dashboard folder from `/FunctionApp-Data/`
- [ ] Update hubName in host.json from `'EntraRiskHub'` to `'AlpenglowHub'`

### 1.3 Directory Structure Verification
Verify final structure:
```
/FunctionApp-Data/
├── host.json (hubName: AlpenglowHub)
├── local.settings.json
├── profile.ps1
├── requirements.psd1
├── Modules/
│   └── EntraDataCollection/
├── Orchestrator/
├── HttpTrigger/
├── TimerTrigger/
├── CollectUsers/
├── CollectEntraGroups/
├── CollectEntraServicePrincipals/
├── ... (all collectors)
├── DeriveEdges/
├── DeriveVirtualEdges/
├── Index*/ functions
├── ProjectGraphToGremlin/
└── GenerateGraphSnapshots/

/FunctionApp-www/
├── host.json (minimal, no DurableTask)
├── local.settings.json (Cosmos connection only)
├── profile.ps1 (simplified)
├── requirements.psd1
└── Dashboard/
    ├── function.json
    └── run.ps1
```

---

## Phase 2: Infrastructure (Bicep) Updates

### 2.1 Naming Convention Changes
- [ ] Update `main.bicep`:
  - [ ] Change `workloadName` default from `'entrarisk'` to `'alpenglow'`
  - [ ] Update Project tag to `'Alpenglow-Alpha'`
  - [ ] Update Version tag to `'1.0-alpha'`
  - [ ] Add new variable: `functionAppWwwName = 'func-${workloadName}-www-${environment}-${uniqueSuffix}'`

### 2.2 Second Function App Resource
- [ ] Add new Function App resource for www (`functionAppWww`)
  - [ ] Use same App Service Plan (shared consumption plan)
  - [ ] System-assigned managed identity (separate from data app!)
  - [ ] Configure with PowerShell runtime 7.4
  - [ ] Link to App Insights
  - [ ] Configure Cosmos DB connection string
  - [ ] Minimal app settings (no Graph, no Storage env vars)

### 2.3 RBAC Changes
- [ ] Data Function App (`func-alpenglow-data-dev-*`):
  - [ ] Keep all existing Graph permissions (15 permissions)
  - [ ] Keep Cosmos DB read/write RBAC
  - [ ] Keep Storage Blob Data Contributor
- [ ] www Function App (`func-alpenglow-www-dev-*`):
  - [ ] Cosmos DB connection string (inherent read/write via string)
  - [ ] NO Graph API permissions needed
  - [ ] NO Storage permissions needed

### 2.4 Update Outputs
- [ ] Add www function app outputs:
  - [ ] `functionAppWwwName`
  - [ ] `functionAppWwwDefaultHostName`
  - [ ] `functionAppWwwPrincipalId`

### 2.5 Timer Trigger Schedule Change
- [ ] Change TimerTrigger schedule from every 6 hours to once daily
  - [ ] Update `FunctionApp-Data/TimerTrigger/function.json` schedule to `"0 0 2 * * *"` (2:00 AM daily)
  - [ ] Update any related documentation

---

## Phase 3: Deployment Script Updates

### 3.1 Update `deploy.ps1`
- [ ] Change default `$ResourceGroupName` from `"rg-entrarisk-v35-001"` to `"rg-alpenglow-dev-001"`
- [ ] Change default `$WorkloadName` from `"entrariskv35"` to `"alpenglow"`
- [ ] Update Project tag to `'Alpenglow-Alpha'`
- [ ] Update Architecture tag to `'Alpenglow-Alpha'`
- [ ] Update banner/messaging to Alpenglow branding

### 3.2 Dual Function App Deployment
- [ ] Add logic to deploy both function apps:
  ```powershell
  # Deploy Data Function App
  Push-Location "$PSScriptRoot/../FunctionApp-Data"
  func azure functionapp publish $dataAppName --powershell
  Pop-Location

  # Deploy www Function App (Dashboard)
  Push-Location "$PSScriptRoot/../FunctionApp-www"
  func azure functionapp publish $wwwAppName --powershell
  Pop-Location
  ```

### 3.3 Graph Permission Assignment
- [ ] Modify Graph permission assignment to ONLY target Data function app
- [ ] www function app gets NO Graph permissions (security isolation!)

---

## Phase 4: Configuration Updates

### 4.1 VSCode Settings
- [ ] Update `.vscode/settings.json`:
  - [ ] Update `azureFunctions.deploySubpath` to `FunctionApp-Data`

### 4.2 Local Settings Templates
- [ ] Create `FunctionApp-Data/local.settings.json.template`
- [ ] Create `FunctionApp-www/local.settings.json.template`

---

## Phase 5: Documentation Updates

### 5.1 Update README
- [ ] Update README-v3.5.md or create new README for Alpenglow
- [ ] Document the two-function-app architecture
- [ ] Document security isolation benefits

---

## Phase 6: New GitHub Repository

### 6.1 Prepare for New Repo
- [ ] Verify `.gitignore` is complete
- [ ] Clean any sensitive data from tracked files
- [ ] Review/update documentation for Alpenglow branding

### 6.2 Create New Repository
- [ ] Create `github.com/gromedev/alpenglow` repository
- [ ] Push project to new repo (including .gitignore)
- [ ] Verify all files present

---

## Testing Checklist

### Pre-Deployment Verification
- [ ] Bicep validates without errors: `az bicep build --file main.bicep`
- [ ] Both FunctionApp directories have valid structure
- [ ] local.settings.json templates are correct

### Post-Deployment Verification
- [ ] Both function apps are created in Azure
- [ ] Data function app has Graph permissions (verify with `az ad sp show`)
- [ ] www function app has NO Graph permissions
- [ ] Dashboard is accessible via www function app URL
- [ ] Data collection works via Data function app
- [ ] Dashboard can read from Cosmos DB

---

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Resource Group                          │
│                    rg-alpenglow-dev-001                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────┐     ┌──────────────────────┐          │
│  │ func-alpenglow-data  │     │ func-alpenglow-www   │          │
│  │ (Data Collection)    │     │ (Dashboard only)     │          │
│  ├──────────────────────┤     ├──────────────────────┤          │
│  │ Managed Identity A   │     │ Managed Identity B   │          │
│  │                      │     │                      │          │
│  │ Permissions:         │     │ Permissions:         │          │
│  │ - 15 Graph APIs      │     │ - Cosmos READ ONLY   │          │
│  │ - Cosmos Read/Write  │     │ - NO Graph API       │          │
│  │ - Storage Read/Write │     │ - NO Storage         │          │
│  └──────────────────────┘     └──────────────────────┘          │
│            │                           │                         │
│            ▼                           ▼                         │
│  ┌─────────────────────────────────────────────────┐            │
│  │              Cosmos DB (Shared)                  │            │
│  │              cosno-alpenglow-dev-*               │            │
│  └─────────────────────────────────────────────────┘            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

If Dashboard (www) is compromised:
- Attacker can only READ Cosmos data (via connection string)
- Cannot access Graph API (no permissions assigned)
- Cannot modify blobs (no storage permissions)
- Cannot affect data collection (separate identity)
```

---

## Notes

### Naming Convention
| Resource Type | Pattern | Example |
|---------------|---------|---------|
| Data Function App | `func-alpenglow-data-{env}-{suffix}` | `func-alpenglow-data-dev-xyz123` |
| www Function App | `func-alpenglow-www-{env}-{suffix}` | `func-alpenglow-www-dev-xyz123` |
| Resource Group | `rg-alpenglow-{env}-001` | `rg-alpenglow-dev-001` |
| Cosmos DB | `cosno-alpenglow-{env}-{suffix}` | `cosno-alpenglow-dev-xyz123` |
| Storage | `stalpenglow{env}{suffix}` | `stalpenglowdevxyz123` |

### What's Being Dropped
- Foundry references (already removed in V3)
- Old EntraRisk naming
- Single-function-app architecture

### Files to Modify
| File | Changes |
|------|---------|
| `Infrastructure/main.bicep` | Naming, tags, add www function app resource, outputs |
| `Scripts/deploy.ps1` | Defaults, tags, dual deployment logic |
| `.vscode/settings.json` | Update deploy subpath |
| `FunctionApp/host.json` | Rename hubName to AlpenglowHub |

---

## Implementation Order (Proposed)

| Step | Work | Impact on Bug |
|------|------|---------------|
| **1. Alpenglow Migration** | Structural changes (split function apps, rebrand) | None - doesn't touch collection code |
| **2. Epic v4** | Rewrite CollectRelationships with `New-EdgeDocument` | **May fix bug** - fresh implementation with better structure |
| **3. Bug debugging** | If still needed after Epic v4 | Cleaner code to debug |

---

## Bug Investigation Notes (January 15, 2026)

### Symptom
Dashboard showed -179 deleted edges after delta sync when only 1 test change was made.

### Root Cause Analysis
**Status: UNRESOLVED** - Root cause not definitively identified.

| Metric | First Full Sync | Subsequent Runs | Actual (from ARM API) |
|--------|-----------------|-----------------|----------------------|
| Azure RBAC | 28 | 9 | **6** |
| appRoleAssignments | 39 | 22 | Unknown |

**Unexplained issues:**
- Why did first sync collect 28 when actual count is 6?
- Why do subsequent runs collect 9 instead of 6?
- Resource groups were deleted during testing - environmental changes not properly tracked

### What Was Tried
1. Added pagination support to Azure RBAC collection using `Get-AzureManagementPagedResult`
2. Verified `Invoke-GraphBatch` handles retries and errors correctly
3. Compared orchestrator inputs (identical between runs)
4. Verified actual ARM API count (6 assignments)

**None of these resolved the discrepancy.**

### Fix Applied (Partial)
Updated `CollectRelationships/run.ps1` Phase 5 (Azure RBAC) to use `Get-AzureManagementPagedResult` for proper pagination handling. However, this did not resolve the count discrepancy.

### Conclusion
The bug remains unresolved. The delete detection may be working correctly, but the edge collection itself has inconsistencies that need further investigation after Epic v4 refactoring provides a cleaner codebase to debug.

### Latest Test Results (January 15, 2026 - Clean Slate Test)

After wiping Cosmos DB and running a clean full sync followed by controlled test changes:

**Test Script Made 20 Modifications:**
- 3 group memberships added, 2 removed (net +1)
- 2 credentials rotated
- 1 PIM eligibility added
- 1 group owner added, 1 removed (net 0)
- 2 app/SP owners added
- 1 direct role added, 1 removed (net 0)
- 1 CA policy exclusion added

**Edge Counts (Correct):**
| Edge Type | Full Sync | Delta Sync | Change | Expected |
|-----------|-----------|------------|--------|----------|
| Total Edges | 700 | 704 | **+4** | ~+4 ✓ |
| groupMembershipsDirect | 246 | 247 | +1 | +1 ✓ |
| appOwners | 21 | 22 | +1 | +1 ✓ |
| spOwners | 22 | 23 | +1 | +1 ✓ |
| pimEligible | 14 | 15 | +1 | +1 ✓ |

**Issue Remaining:**
Dashboard shows: `+265 new / ~113 mod / -122 del`

The **122 deleted** is wrong - only ~4 deletions were expected. The edge *counts* are correct, but the *audit tracking* is over-reporting deletions.

The indexer is writing 153 CosmosWrites for edges, but only 31 actual changes (21 modified + 10 new). The extra 122 writes are being recorded as deletes.

**Likely Cause:** The `IndexEdgesInCosmosDB` function may be treating edge property changes (like timestamps) as delete+create pairs rather than modifications.

### Recommendation
Proceed with Epic v4 implementation, which will rewrite all 17 collection phases with better structure. Any remaining edge collection issues will be easier to debug with the cleaner codebase.
