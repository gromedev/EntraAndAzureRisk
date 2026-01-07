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
- Not a source of truth—Cosmos SQL containers are authoritative (delta-updated)
- Not a history or audit store
- Not part of the dashboard polling loop

### Core Assumption
> "I can drop and fully rebuild Gremlin from Cosmos SQL containers at any time."

This makes Gremlin **disposable**, eliminating migration complexity and schema evolution pain.

### Data Source Clarification

| Source | Retention | Use for Gremlin? |
|--------|-----------|------------------|
| **JSONL Blobs** | 90 days (lifecycle policy) | ❌ Not reliable long-term |
| **Cosmos SQL** (`principals`, `relationships`) | Permanent (delta-updated) | ✅ **Primary source** |
| **Changes container** | Permanent (audit trail) | For historical graph replay |

**Important:** The cost optimization strategy relies on **delta change tracking**—only changed entities are written to Cosmos. Gremlin projection should follow the same pattern: project from Cosmos SQL (current state), not from blobs.

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

## Appendix A: Current Data Structure Assessment

> **Verdict:** The current structure is **already graph-friendly**. No restructuring required.

### Current Cosmos DB Containers

| Container | Partition Key | Purpose | Gremlin Role |
|-----------|---------------|---------|--------------|
| `principals` | `/objectId` | Users, groups, SPs, apps, devices | **Vertices** |
| `relationships` | `/sourceId` | Entra relationships (memberships, roles, ownership) | **Edges** |
| `azureResources` | `/resourceType` | Tenant, MGs, subs, RGs, KeyVaults, VMs | **Vertices** |
| `azureRelationships` | `/sourceId` | Azure hierarchy, keyVaultAccess, managedIdentity | **Edges** |
| `policies` | `/policyType` | CA policies, role policies, named locations | Not needed |
| `changes` | `/changeDate` | Immutable change history | Not needed |
| `events` | `/eventDate` | Sign-in and audit events | Not needed |

### Why This Structure Works

**1. Clear Vertex Sources**
```
principals        → Gremlin vertices (label = principalType)
azureResources    → Gremlin vertices (label = resourceType)
```

Every entity has a stable `objectId` that becomes the Gremlin vertex ID.

**2. Clear Edge Sources**
```
relationships      → Gremlin edges (label = relationType)
azureRelationships → Gremlin edges (label = relationType)
```

Every relationship has explicit `sourceId` → `targetId` linking—exactly what Gremlin needs.

**3. Partition Keys Support Traversal**

The `sourceId` partition key on relationship containers means:
- Source-rooted queries are partition-efficient
- "What can user X reach?" queries stay within partition
- No cross-partition scatter for typical traversal patterns

### Document-to-Gremlin Mapping

**Principals → Vertices**

```
Cosmos SQL Document:                    Gremlin Vertex:
┌─────────────────────────────────┐     ┌─────────────────────────┐
│ {                               │     │ g.addV('user')          │
│   "objectId": "user-123",       │ ──► │   .property('id', 'user-123')
│   "principalType": "user",      │     │   .property('tenantId', 'tenant-abc')
│   "displayName": "John Doe",    │     │                         │
│   "accountEnabled": true,       │     │ // displayName, etc.    │
│   ...40 more fields...          │     │ // NOT copied to Gremlin│
│ }                               │     └─────────────────────────┘
└─────────────────────────────────┘
```

**Relationships → Edges**

```
Cosmos SQL Document:                    Gremlin Edge:
┌─────────────────────────────────┐     ┌─────────────────────────┐
│ {                               │     │ g.V('group-456')        │
│   "sourceId": "group-456",      │ ──► │   .addE('groupMember')  │
│   "targetId": "user-123",       │     │   .to(g.V('user-123'))  │
│   "relationType": "groupMember",│     │                         │
│   "sourceDisplayName": "...",   │     │ // Denormalized fields  │
│   "membershipType": "direct",   │     │ // NOT copied to Gremlin│
│   ...20 more fields...          │     └─────────────────────────┘
│ }                               │
└─────────────────────────────────┘
```

### What Maps Directly (No Changes)

| Current Field | Gremlin Element | Notes |
|---------------|-----------------|-------|
| `objectId` | Vertex `id` | Stable, immutable |
| `principalType` / `resourceType` | Vertex `label` | Enables `hasLabel()` filtering |
| `sourceId` | Edge source vertex | Direct mapping |
| `targetId` | Edge target vertex | Direct mapping |
| `relationType` | Edge `label` | Enables edge-type filtering |

### What We Intentionally Skip

These fields exist in SQL but should **NOT** go into Gremlin:

| Field | Why Skip |
|-------|----------|
| `displayName` | Resolve from SQL when needed |
| `accountEnabled`, `userType`, etc. | Property data, not graph structure |
| `collectionTimestamp` | History stays in blobs |
| `memberCountDirect`, analytics fields | Computed summaries, not edges |
| `inheritancePath` (on transitive) | Already represented as edges |

### Projection Logic (Pseudocode)

```powershell
# From principals container → Gremlin vertices
foreach ($principal in $principals) {
    $vertex = @{
        id    = $principal.objectId
        label = $principal.principalType  # user, group, servicePrincipal, etc.
        tenantId = $tenantId
    }
    Add-GremlinVertex $vertex
}

# From azureResources container → Gremlin vertices
foreach ($resource in $azureResources) {
    $vertex = @{
        id    = $resource.objectId
        label = $resource.resourceType  # subscription, keyVault, virtualMachine, etc.
        tenantId = $tenantId
    }
    Add-GremlinVertex $vertex
}

# From relationships container → Gremlin edges
foreach ($rel in $relationships | Where-Object { $_.relationType -in $traversableTypes }) {
    $edge = @{
        from  = $rel.sourceId
        to    = $rel.targetId
        label = $rel.relationType
    }
    # Optional: add scopeId for RBAC edges
    if ($rel.relationType -eq 'azureRbac') {
        $edge.scopeId = $rel.scope
    }
    Add-GremlinEdge $edge
}

# From azureRelationships container → Gremlin edges
foreach ($rel in $azureRelationships) {
    $edge = @{
        from  = $rel.sourceId
        to    = $rel.targetId
        label = $rel.relationType
    }
    Add-GremlinEdge $edge
}
```

### Special Cases

**1. Transitive Group Membership**

We store `groupMemberTransitive` relationships with `inheritancePath`. For Gremlin:
- **Option A:** Skip transitive edges (Gremlin computes them via `repeat().out()`)
- **Option B:** Include them as edges for faster bounded queries

Recommendation: **Option A** initially. Gremlin excels at transitive traversal.

**2. Azure RBAC Scoping**

RBAC relationships have a `scope` field (subscription, resource group, resource). For Gremlin:
- Store `scopeId` as edge property if needed for filtered traversal
- Or resolve scope from SQL after path discovery

**3. Directory Roles**

Directory roles are stored as relationships with `targetId` = role template ID. The role itself isn't in `principals`. Options:
- Add role template IDs as synthetic vertices (label = `directoryRole`)
- Or query relationships directly by role template ID

Recommendation: Add synthetic role vertices for cleaner traversal.

### Conclusion

**No restructuring needed.** The current design with:
- `principals` + `azureResources` → vertices
- `relationships` + `azureRelationships` → edges

...maps directly to Gremlin. The Graph Projector function simply:
1. Reads from **Cosmos SQL containers** (not blobs—they expire after 90 days)
2. Extracts `id`, `label`, `sourceId`, `targetId`
3. Writes minimal vertices + edges to Gremlin

The denormalized fields in SQL remain untouched—they're for BI and dashboards, not graph traversal.

### Delta Strategy for Gremlin

To align with the cost optimization strategy (delta change tracking), the Graph Projector should:

1. **Full rebuild (initial or periodic):** Query all principals + relationships → write to Gremlin
2. **Incremental updates:** Subscribe to `changes` container or use change feed to update only modified vertices/edges

This mirrors the existing pattern: expensive operations happen once, incremental updates are cheap.

---

## Appendix B: One-Sentence Summary

> Use Cosmos SQL containers as the delta-updated source of truth, project a minimal, disposable relationship graph into Gremlin, render static snapshots for dashboards, and treat Gremlin as an on-demand query accelerator—not a database.

---

**End of Proposal**
