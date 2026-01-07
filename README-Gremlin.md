# Proposal: Graph Visualization Layer with Cosmos DB Gremlin API

> **Status:** Draft
> **Date:** 2026-01-07
> **Author:** Architecture Review

---

## Executive Summary

This proposal outlines how to add graph-based attack path visualization to the EntraAndAzureRisk project using Azure Cosmos DB Gremlin API. The key insight is that **Gremlin should be a query accelerator, not a database**—a thin, disposable traversal index over existing data.

**Estimated Cost:** $5-20/month additional
**Complexity:** Low—no changes to existing architecture
**Value:** Enables BloodHound-style path queries ("Who can reach Global Admin?") 

---

## 1. Design Principles

### What Gremlin Is
- A **query accelerator** for transitive/path-based questions
- A **runtime graph index** built from relationships we already model
- A **materialized traversal index** over the `relationships` container

### What Gremlin Is NOT
- Not a replacement for `principals`, `relationships`, or `changes` containers
- Not a source of truth—blobs remain authoritative
- Not a history or audit store
- Not part of the dashboard polling loop

### Core Assumption
> "I can drop and fully rebuild Gremlin from blobs at any time."

This makes Gremlin **disposable**, eliminating migration complexity and schema evolution pain.

---

## 2. Current Architecture (Unchanged)

```
Entra/Azure APIs
       ↓
   Collectors (run.ps1)
       ↓
   JSONL → Blob Storage (authoritative, immutable, cheap)
       ↓
   Indexers → Cosmos DB SQL API
              ├── principals (entities)
              ├── relationships (edges)
              ├── policies (CA, etc.)
              ├── changes (delta history)
              └── events (sign-ins)
       ↓
   Dashboard (Power BI / Web)
```

**This architecture remains 100% intact.** Gremlin is additive.

---

## 3. Proposed Architecture

```
Existing Pipeline (unchanged)
       ↓
   JSONL Blobs ──────────────────┐
       ↓                         ↓
   Cosmos SQL API         Graph Projector (NEW)
   (principals,                  ↓
    relationships,        Cosmos Gremlin API (NEW)
    changes, etc.)        (minimal vertices + edges)
       ↓                         ↓
   Dashboard ←───────────── Static Snapshots
                                 ↓
                          On-Demand Live Queries
```

### Data Flow
1. **Collection** → JSONL blobs (no change)
2. **Indexing** → Cosmos SQL (no change)
3. **NEW: Graph Projection** → Extract IDs + edges → Gremlin
4. **NEW: Snapshot Generation** → Pre-render common paths → Blob as SVG/PNG
5. **Dashboard** → Shows static snapshots with "Launch live analysis →" links

---

## 4. Minimal Gremlin Data Model

### Vertices (One per Principal)

```json
{
  "id": "objectId",
  "label": "principalType",
  "tenantId": "tenantId"
}
```

**That's it.** No displayName, no timestamps, no metadata bloat. Those are resolved from SQL/blobs when needed.

### Edges (Subset of Relationships)

Only relationships that participate in traversal:

| Include | Exclude |
|---------|---------|
| `groupMember` | `license` |
| `groupMemberTransitive` | `oauth2PermissionGrant` (unless attack-path) |
| `directoryRole` | Terminal/descriptive relationships |
| `pimEligible` | |
| `pimActive` | |
| `azureRbac` | |
| `appRoleAssignment` | |
| `contains` | |
| `hasManagedIdentity` | |
| `keyVaultAccess` | |

```json
{
  "from": "sourceId",
  "to": "targetId",
  "label": "relationType"
}
```

Optional edge properties:
- `scopeId` (for Azure RBAC scoping)
- `assignmentType` (eligible vs active)

**Nothing else.**

---

## 5. Query Split Pattern

| Question Type | Store | Example |
|---------------|-------|---------|
| "What is this object?" | SQL / Blob | Get user details |
| "Show raw state at time T" | Blob | Historical audit |
| "Who transitively has access to X?" | **Gremlin** | Path traversal |
| "Why does user have role Y?" | **Gremlin → IDs → SQL** | Resolve path |

**Pattern:** Gremlin returns IDs only. Resolution happens against blob/SQL.

---

## 6. Static Snapshots + On-Demand Queries

### Static Snapshots (Dashboard)

Pre-render common attack paths during indexing:

```
raw-data/
  2026-01-07T12-00-00Z/
    users.jsonl
    relationships.jsonl
    snapshots/
      paths-to-global-admin.svg
      dangerous-service-principals.svg
      external-user-exposure.svg
      high-risk-app-permissions.svg
```

**Dashboard shows:**
> ![Attack Path Snapshot](blob://snapshots/paths-to-global-admin.svg)
> *Snapshot from 2026-01-07 12:00 UTC*
> *[Launch live analysis →]*

### On-Demand Live Queries (Gremlin)

Only invoked when user clicks "Launch live analysis":

```gremlin
// "Why does user X have this role?"
g.V('user-id').repeat(out()).until(hasLabel('directoryRole')).path()

// "Who can reach Global Admin through any path?"
g.V().hasLabel('directoryRole').has('roleTemplateId', 'global-admin-id')
  .repeat(__.in()).emit().path()

// "Blast radius if this group is compromised"
g.V('group-id').repeat(out()).emit().hasLabel('directoryRole')
```

These queries are **impossible or cost-prohibitive** in SQL.

---

## 7. Cost Analysis

### Why This Stays Cheap

| Factor | Impact |
|--------|--------|
| Graph contains IDs + edges only | Orders of magnitude less data |
| No history in Gremlin | No storage bloat |
| No dashboard polling | RUs only burn on explicit requests |
| Serverless mode | Pay only for actual queries |
| Rebuildable from blobs | No migration complexity |

### Estimated Monthly Costs

| Component | When It Runs | Cost |
|-----------|--------------|------|
| Snapshot generation | Once per collection cycle | ~$0 (blob write) |
| Dashboard display | Every view | ~$0 (blob read) |
| Gremlin queries | On explicit request | $0.25/M RUs |

### Realistic Scenarios

| Scenario | Gremlin Cost | Total System |
|----------|--------------|--------------|
| Dev/Test (occasional queries) | $5-10/month | ~$15-20/month |
| Small Production | $10-20/month | ~$25-35/month |
| Medium Production | $20-50/month | ~$40-70/month |

**Key constraint:** Don't poll Gremlin from dashboards. Static snapshots handle 80% of visualization needs.

---

## 8. Implementation Approach

### Phase 1: Graph Projector Function

**New file:** `FunctionApp/ProjectGraphToGremlin/run.ps1`

```powershell
# Read relationships from JSONL or Cosmos SQL
# Emit minimal vertices + edges to Gremlin
# Run after indexing completes
```

**Trigger:** Orchestrator calls after `IndexRelationshipsInCosmosDB`

### Phase 2: Snapshot Generator

**New file:** `FunctionApp/GenerateGraphSnapshots/run.ps1`

```powershell
# Query Gremlin for common attack paths
# Render as SVG using graph layout library
# Upload to blob storage
```

**Snapshots to generate:**
1. Top 10 shortest paths to Global Admin
2. Service principals with dangerous permissions
3. External users with privileged access
4. Blast radius of role-assignable groups

### Phase 3: Dashboard Integration

Add snapshot images to existing dashboard with links to live query interface.

### Infrastructure

```bicep
// Add to existing Cosmos DB deployment
resource gremlinDatabase 'Microsoft.DocumentDB/databaseAccounts/gremlinDatabases@2024-05-15' = {
  name: 'GraphIndex'
  properties: {
    resource: { id: 'GraphIndex' }
    options: { throughput: 400 }  // Or serverless
  }
}
```

---

## 9. What This Enables

### Queries That Become Trivial

```gremlin
// "Why does user X have this role?"
User → Group → Group → Role
User → Eligible → Active → Role

// "Who can reach Global Admin through any path?"
repeat(out()).until(hasLabel('directoryRole'))

// "Blast radius if this group is compromised"
g.V(groupId).repeat(out()).emit().hasLabel('directoryRole')

// "Attack path across Azure + Entra"
User → Group → Role → Subscription → Resource
```

### Use Cases Unlocked

| Use Case | Value |
|----------|-------|
| Attack path discovery | BloodHound-style queries |
| Incident response | "How did attacker reach X?" |
| Access reviews | "Why does this user have access?" |
| Risk visualization | Static dashboard graphs |

---

## 10. Alignment with Existing Principles

| Existing Principle | Gremlin Impact |
|--------------------|----------------|
| Collect Everything | Unchanged |
| Collect Once | Unchanged |
| Denormalize for BI | Stays in SQL |
| Wide tables | Stays in SQL |
| Delta detection | Unchanged |
| Historical tracking | Unchanged |
| ObjectID immutability | **Enables** Gremlin (stable vertex IDs) |

**Gremlin adds zero pressure on existing design.**

---

## 11. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Dashboard polling Gremlin | Use static snapshots; Gremlin is on-demand only |
| Cost explosion | Minimal data model; serverless mode |
| Data drift | Periodic full rebuild from blobs |
| Schema evolution | Gremlin is disposable; rebuild anytime |

---

## 12. Recommendation

**Proceed with implementation.** The architecture is sound:

1. **Blobs remain authoritative** — no new truth sources
2. **Gremlin is disposable** — can drop and rebuild anytime
3. **Costs stay low** — minimal data, on-demand queries only
4. **Static snapshots** — dashboard visualization without Gremlin polling
5. **No refactoring** — purely additive to existing pipeline

### Next Steps

1. Create `ProjectGraphToGremlin` function
2. Create `GenerateGraphSnapshots` function
3. Add Gremlin database to Bicep templates
4. Integrate snapshots into dashboard

---

## Appendix: One-Sentence Summary

> Use Blob Storage as immutable truth, project a minimal, disposable relationship graph into Gremlin, render static snapshots for dashboards, and treat Gremlin as an on-demand query accelerator—not a database.

---

**End of Proposal**
