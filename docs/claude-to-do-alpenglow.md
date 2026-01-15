# Alpenglow Alpha Migration To-Do List

## Migration Status: COMPLETE (Ready for Deployment)

**Last Updated:** 2026-01-15
**Completed Phases:** 6/6 (Phase 6.2 - manual GitHub repo creation - pending)

### Summary of Changes
- Created `FunctionApp-www/` with Dashboard (security-isolated)
- Renamed `FunctionApp/` to `FunctionApp-Data/`
- Updated Bicep: serverless Cosmos DB, added www function app, updated naming
- Updated deploy.ps1: dual function app deployment, Alpenglow branding
- Updated VSCode settings and created local.settings.json templates
- Created `docs/README-Alpenglow-Alpha.md`

---

## Overview
Migrating EntraAndAzureRisk (v3.5) to Alpenglow Alpha with separate Function Apps for security isolation.

## Design Decisions (Confirmed)
- **Naming suffix**: Keep `uniqueString()` for globally unique names
- **App Service Plan**: Shared consumption (Y1) plan for both function apps
- **Security isolation**: Separate managed identities (not separate plans)
- **Dashboard route**: Keep `/api/dashboard` path

---

## Phase 1: Project Structure Changes

### 1.1 Separate Dashboard into its own Function App
- [x] Create `/FunctionApp-www/` directory structure
  - [x] Create `host.json` (minimal - no DurableTask needed)
  - [x] Create `profile.ps1` (simplified - no module loading needed)
  - [x] Create `requirements.psd1`
  - [x] Copy `Dashboard/` function to `/FunctionApp-www/Dashboard/`
  - [x] Update Dashboard branding to "Alpenglow Dashboard (Alpha)"
  - [x] The www function app does NOT need Modules/ (Dashboard uses Cosmos bindings only)

### 1.2 Rename FunctionApp to FunctionApp-Data
- [x] Rename `/FunctionApp/` to `/FunctionApp-Data/`
- [x] Remove Dashboard folder from `/FunctionApp-Data/`
- [x] Update hubName in host.json from `'EntraRiskHub'` to `'AlpenglowHub'`

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

### 2.0 Fix Cosmos DB Capacity Mode (Cost Bug)
- [x] Update `main.bicep` line 150:
  - **Current:** `capabilities: []` (deploys as provisioned, ~$120/month)
  - **Required:** Add `EnableServerless` capability (~$8/month)
  ```bicep
  capabilities: [
    {
      name: 'EnableServerless'
    }
  ]
  ```
- [x] Change backup policy from `Continuous` to `Periodic` (serverless doesn't support continuous backup)
  ```bicep
  backupPolicy: {
    type: 'Periodic'
    periodicModeProperties: {
      backupIntervalInMinutes: 240
      backupRetentionIntervalInHours: 8
    }
  }
  ```
- [x] Remove throughput settings from containers (serverless manages this automatically)

**Note:** This cannot be changed on an existing account. The Alpenglow migration will deploy a new account, fixing this automatically.

### 2.1 Naming Convention Changes
- [x] Update `main.bicep`:
  - [x] Change `workloadName` default from `'entrarisk'` to `'alpenglow'`
  - [x] Update Project tag to `'Alpenglow-Alpha'`
  - [x] Update Version tag to `'1.0-alpha'`
  - [x] Add new variable: `functionAppWwwName = 'func-${workloadName}-www-${environment}-${uniqueSuffix}'`

### 2.2 Second Function App Resource
- [x] Add new Function App resource for www (`functionAppWww`)
  - [x] Use same App Service Plan (shared consumption plan)
  - [x] System-assigned managed identity (separate from data app!)
  - [x] Configure with PowerShell runtime 7.4
  - [x] Link to App Insights
  - [x] Configure Cosmos DB connection string
  - [x] Minimal app settings (no Graph, no Storage env vars)

### 2.3 RBAC Changes
- [x] Data Function App (`func-alpenglow-data-dev-*`):
  - [x] Keep all existing Graph permissions (15 permissions)
  - [x] Keep Cosmos DB read/write RBAC
  - [x] Keep Storage Blob Data Contributor
- [x] www Function App (`func-alpenglow-www-dev-*`):
  - [x] Cosmos DB connection string (inherent read/write via string)
  - [x] NO Graph API permissions needed
  - [x] NO Storage permissions needed

### 2.4 Update Outputs
- [x] Add www function app outputs:
  - [x] `functionAppWwwName`
  - [x] `functionAppWwwDefaultHostName`
  - [x] `functionAppWwwPrincipalId`

---

## Phase 3: Deployment Script Updates

### 3.1 Update `deploy.ps1`
- [x] Change default `$ResourceGroupName` from `"rg-entrarisk-v35-001"` to `"rg-alpenglow-dev-001"`
- [x] Change default `$WorkloadName` from `"entrariskv35"` to `"alpenglow"`
- [x] Update Project tag to `'Alpenglow-Alpha'`
- [x] Update Architecture tag to `'Alpenglow-Alpha'`
- [x] Update banner/messaging to Alpenglow branding

### 3.2 Dual Function App Deployment
- [x] Add logic to deploy both function apps:
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
- [x] Modify Graph permission assignment to ONLY target Data function app
- [x] www function app gets NO Graph permissions (security isolation!)

---

## Phase 4: Configuration Updates

### 4.1 VSCode Settings
- [x] Update `.vscode/settings.json`:
  - [x] Update `azureFunctions.deploySubpath` to `FunctionApp-Data`

### 4.2 Local Settings Templates
- [x] Create `FunctionApp-Data/local.settings.json.template`
- [x] Create `FunctionApp-www/local.settings.json.template`

---

## Phase 5: Documentation Updates

### 5.1 Update README
- [x] Update README-v3.5.md or create new README for Alpenglow
- [x] Document the two-function-app architecture
- [x] Document security isolation benefits

**Created:** `docs/README-Alpenglow-Alpha.md`

---

## Phase 6: New GitHub Repository

### 6.1 Prepare for New Repo
- [x] Verify `.gitignore` is complete
- [x] Clean any sensitive data from tracked files
- [x] Review/update documentation for Alpenglow branding

### 6.2 Create New Repository
- [ ] Create `github.com/gromedev/alpenglow` repository (manual)
- [ ] Push project to new repo (including .gitignore)
- [ ] Verify all files present

---

## Testing Checklist

### Pre-Deployment Verification
- [x] Bicep validates without errors: `az bicep build --file main.bicep`
- [x] Both FunctionApp directories have valid structure
- [x] local.settings.json templates are correct

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

### Files Modified
| File | Changes | Status |
|------|---------|--------|
| `Infrastructure/main.bicep` | Naming, tags, serverless Cosmos, add www function app resource, outputs | Done |
| `Scripts/deploy.ps1` | Defaults, tags, dual deployment logic | Done |
| `.vscode/settings.json` | Update deploy subpath to FunctionApp-Data | Done |
| `FunctionApp-Data/host.json` | Rename hubName to AlpenglowHub | Done |
| `FunctionApp-www/*` | New directory with Dashboard only | Done |
| `docs/README-Alpenglow-Alpha.md` | New architecture documentation | Done |

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
**Status: UNRESOLVED** - Root cause not identified after 3+ hours of investigation.

### What Was Tried (None of these fixed the issue)
1. Added pagination support to Azure RBAC collection using `Get-AzureManagementPagedResult` - **DID NOT FIX**
2. Verified `Invoke-GraphBatch` handles retries and errors correctly - **NOT THE CAUSE**
3. Compared orchestrator inputs (identical between runs) - **NOT THE CAUSE**
4. Verified actual ARM API count (6 assignments) - **INFORMATIONAL ONLY**
5. Wiped Cosmos DB and ran clean slate test - **BUG STILL PRESENT**

### Clean Slate Test Results (January 15, 2026)

After wiping Cosmos DB and running controlled test with 20 modifications:

**Edge Counts (Correct):**
| Edge Type | Full Sync | Delta Sync | Change | Expected |
|-----------|-----------|------------|--------|----------|
| Total Edges | 700 | 704 | **+4** | ~+4 ✓ |
| groupMembershipsDirect | 246 | 247 | +1 | +1 ✓ |
| appOwners | 21 | 22 | +1 | +1 ✓ |
| spOwners | 22 | 23 | +1 | +1 ✓ |
| pimEligible | 14 | 15 | +1 | +1 ✓ |

**Audit Tracking (WRONG):**
Dashboard shows: `+265 new / ~113 mod / -122 del`

The **122 deleted** is wrong - only ~4 deletions were expected.

### Issue Summary
- Edge *counts* are correct
- Audit *tracking* is over-reporting deletions
- The indexer writes 153 CosmosWrites for edges, but only 31 actual changes (21 modified + 10 new)
- The extra 122 writes are being recorded as deletes

**Likely Cause:** `IndexEdgesInCosmosDB` function may be treating edge property changes as delete+create pairs rather than modifications.

### Recommendation
Proceed with Epic v4 implementation. The bug requires deeper investigation into the indexing logic, which will be easier with the cleaner codebase from Epic v4.
