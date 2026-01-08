# Entra Risk Data Architecture (V3.5)

> **Version:** 3.5
> **Last Updated:** 2026-01-08
> **Branch:** Version-3
> **Purpose:** Architecture specification for the Entra Risk data collection, analysis, and attack path discovery platform.

---

## Overview

A data collection and analysis platform that:
- Collects Entra ID and Azure security data via Microsoft Graph API and Azure Resource Manager API
- Stores data in Cosmos DB with intelligent delta detection (~99% write reduction)
- Enables historical trend analysis, audit correlation, and attack path discovery
- Projects data to Gremlin graph database for attack path traversal
- Generates pre-rendered attack path snapshots (DOT/SVG)
- Powers dashboards and Power BI reporting

### High-Level Architecture

```mermaid
flowchart TB
    subgraph Sources["Data Sources"]
        Graph["Microsoft Graph API"]
        Azure["Azure Resource Manager"]
    end

    subgraph FunctionApp["Azure Function App (17 Collectors + 5 Indexers + 2 Graph Functions)"]
        Orch["Orchestrator"]
        subgraph PrincipalCollectors["Principal Collectors (4)"]
            UC["Users"]
            GC["Groups"]
            SPC["Service Principals"]
            DC["Devices"]
        end
        subgraph ResourceCollectors["Resource Collectors (10)"]
            AC["App Registrations"]
            AHC["Azure Hierarchy"]
            KVC["Key Vaults"]
            VMC["Virtual Machines"]
            AAC["Automation Accounts"]
            FAC["Function Apps"]
            LAC["Logic Apps"]
            WAC["Web Apps"]
            DRC["Directory Role Definitions"]
            ARC["Azure Role Definitions"]
        end
        subgraph OtherCollectors["Other Collectors (3)"]
            RC["Relationships"]
            PC["Policies"]
            EC["Events"]
        end
        subgraph Indexers["Indexers (5)"]
            PI["Principals"]
            RSI["Resources"]
            EI["Edges"]
            PLI["Policies"]
            EVI["Events"]
        end
        subgraph GraphFunctions["Graph Functions (2)"]
            PGG["Project to Gremlin"]
            GSS["Generate Snapshots"]
        end
    end

    subgraph Storage["Storage Layer"]
        Blob["Azure Blob Storage<br/>(5 unified JSONL files)"]
        Cosmos["Cosmos DB SQL API<br/>(6 containers)"]
        Gremlin["Cosmos DB Gremlin API<br/>(Graph database)"]
    end

    subgraph Consumers["Consumers"]
        Dashboard["Dashboard API"]
        PowerBI["Power BI"]
        PathQueries["Attack Path Queries"]
        Snapshots["Static Snapshots"]
    end

    Graph --> PrincipalCollectors
    Graph --> OtherCollectors
    Azure --> ResourceCollectors
    Orch -->|"triggers"| PrincipalCollectors
    Orch -->|"triggers"| ResourceCollectors
    Orch -->|"triggers"| OtherCollectors
    PrincipalCollectors -->|"stream"| Blob
    ResourceCollectors -->|"stream"| Blob
    OtherCollectors -->|"stream"| Blob
    Orch -->|"triggers"| Indexers
    Blob --> Indexers
    Indexers -->|"~99% reduction"| Cosmos
    Cosmos --> Dashboard
    Cosmos --> PowerBI
    Cosmos -->|"audit changes"| PGG
    PGG -->|"vertices/edges"| Gremlin
    Gremlin --> GSS
    GSS -->|"DOT/JSON"| Blob
    Gremlin --> PathQueries
    Blob --> Snapshots
```

---

## What's New in V3.5

| Change | Description |
|--------|-------------|
| **Attack Path Snapshots** | Pre-rendered Gremlin query results for common attack patterns (DOT format) |
| **Gremlin Graph Projection** | Timer-triggered sync from audit container to Gremlin graph database |
| **6 New Edge Types** | CA policy edges (5) + Role management policy edges (1) |
| **2 New Collectors** | Directory Role Definitions + Azure Role Definitions (synthetic vertices) |
| **Synthetic Vertices** | Role definitions as queryable vertices with `isPrivileged` flags |
| **CA Policy Analysis** | Edges show which principals are targeted/excluded from CA policies |
| **PIM Policy Analysis** | Edges show role activation requirements (MFA, approval, justification) |

### V3 Features (Retained)

| Change | Description |
|--------|-------------|
| **Semantic Correctness** | Applications moved from `principals` to `resources` container (they're resources, not principals) |
| **Unified Edges** | All relationships (Entra + Azure) consolidated into single `edges` container with `edgeType` discriminator |
| **Unified Resources** | Applications + all Azure resources in single `resources` container with `resourceType` discriminator |
| **Temporal Fields** | `effectiveFrom`/`effectiveTo` on all entities for historical queries |
| **Unified Blobs** | 5 consolidated JSONL files instead of 15+ separate files |
| **6 Cosmos Containers** | Down from 9 (principals, resources, edges, policies, events, audit) |
| **roleManagement API** | Migrated from legacy DirectoryRole API to unified roleManagement API |
| **8 Azure Collectors** | Automation Accounts, Function Apps, Logic Apps, Web Apps |

---

## Design Principles

| # | Principle | Description |
|---|-----------|-------------|
| 1 | **Collect Everything** | All properties, all relationships - comprehensive data capture |
| 2 | **Collect Once** | Each relationship from the most efficient API direction only |
| 3 | **Denormalize Generously** | Include displayNames and filter fields in relationships |
| 4 | **Wide Tables** | Minimize joins, maximize queryability for Power BI |
| 5 | **Delta Detection** | Only write changes to Cosmos (~99% reduction after first run) |
| 6 | **Historical Tracking** | Keep ALL changes permanently - enable trend analysis over years |
| 7 | **Minimal Change Records** | Store only delta (changed fields), not full entity copies |
| 8 | **Gremlin-Ready** | Unified edges container designed for graph projection |
| 9 | **Attack Path First** | Edge types capture security-relevant relationships for path traversal |

**Key insight:** ObjectIDs are immutable (never change), making them ideal for partition keys and stable references. DisplayNames are denormalized for convenience but relationships are keyed by ObjectID.

---

## Data Flow

```mermaid
sequenceDiagram
    participant Timer as Timer Trigger
    participant Orch as Orchestrator
    participant PrinColl as Principal Collectors (4)
    participant ResColl as Resource Collectors (10)
    participant EdgeColl as Edge Collector
    participant Graph as Graph API
    participant ARM as ARM API
    participant Blob as Blob Storage
    participant Idx as Indexers (5)
    participant Cosmos as Cosmos DB
    participant GremProj as Gremlin Projector
    participant GremDB as Gremlin Graph
    participant SnapGen as Snapshot Generator

    Timer->>Orch: Trigger (scheduled)

    par Phase 1: Principal + Resource Collection
        Orch->>PrinColl: Start collection
        PrinColl->>Graph: Request data (paginated)
        Graph-->>PrinColl: Response (with retry/throttle)
        PrinColl->>Blob: Stream to principals.jsonl
    and
        Orch->>ResColl: Start collection
        ResColl->>ARM: Request data (per subscription)
        ResColl->>Graph: Request role definitions
        ARM-->>ResColl: Response
        Graph-->>ResColl: Response
        ResColl->>Blob: Stream to resources.jsonl
    end

    Orch->>EdgeColl: Phase 2: Collect relationships
    EdgeColl->>Graph: Request relationships + CA policies
    EdgeColl->>Blob: Stream to edges.jsonl

    Orch->>Idx: Phase 3: Trigger indexing

    loop For each entity in JSONL
        Idx->>Cosmos: Query existing record
        Cosmos-->>Idx: Current state (or null)

        alt New entity
            Idx->>Cosmos: Write to container + change record to audit
        else Modified
            Idx->>Cosmos: Update container + write delta to audit
        else Unchanged
            Note over Idx: Skip (~99% of records)
        end
    end

    Note over GremProj: Timer: Every 15 minutes
    GremProj->>Cosmos: Query audit for changes
    Cosmos-->>GremProj: Recent change records
    GremProj->>GremDB: Upsert vertices (principals, resources)
    GremProj->>GremDB: Upsert edges (relationships)

    Note over SnapGen: Timer: Hourly
    SnapGen->>GremDB: Execute attack path queries
    GremDB-->>SnapGen: Path results
    SnapGen->>Blob: Upload DOT/JSON snapshots
```

---

### Orchestration Phases

| Phase | Collectors | Output | Parallelism |
|-------|------------|--------|-------------|
| **Phase 1** | Users, Groups, SPs, Devices | principals.jsonl | 4 parallel |
| **Phase 1** | Apps, Azure Hierarchy, Key Vaults, VMs, Automation, Functions, Logic Apps, Web Apps, Directory Role Defs, Azure Role Defs | resources.jsonl | 10 parallel |
| **Phase 1** | Policies | policies.jsonl | 1 |
| **Phase 1** | Events | events.jsonl | 1 |
| **Phase 2** | Relationships (all edge types incl. CA policy edges) | edges.jsonl | 1 |
| **Phase 3** | All 5 indexers | → Cosmos DB | Sequential per type |

### Graph Functions (Timer-Triggered)

| Function | Schedule | Purpose |
|----------|----------|---------|
| `ProjectGraphToGremlin` | Every 15 min | Sync audit changes to Gremlin graph |
| `GenerateGraphSnapshots` | Hourly | Generate attack path snapshots (DOT/JSON) |

### Key Patterns
- **Streaming to blob** - Memory efficient, handles any data volume
- **Append blob with If-None-Match** - Prevents race conditions when multiple collectors write to same file
- **Delta detection** - Field-based comparison, ~99% write reduction
- **Retry with backoff** - Handles Graph API throttling
- **Parallel collection** - Multiple collectors run concurrently
- **Temporal tracking** - `effectiveFrom`/`effectiveTo` for point-in-time queries
- **Watermark-based sync** - Gremlin projector tracks last sync timestamp
- **Fold/coalesce upserts** - Idempotent Gremlin vertex/edge operations

---

## Storage Structure

### Cosmos DB Containers (6 SQL + 1 Gremlin)

```mermaid
flowchart LR
    subgraph BlobOutput["Unified Blob Output"]
        PRIN["principals.jsonl"]
        RES["resources.jsonl"]
        EDGE["edges.jsonl"]
        POL["policies.jsonl"]
        EVT["events.jsonl"]
    end

    subgraph CosmosSql["Cosmos DB SQL API (6 Containers)"]
        P["principals<br/>───────────<br/>/objectId"]
        R["resources<br/>───────────<br/>/resourceType"]
        E["edges<br/>───────────<br/>/edgeType"]
        PO["policies<br/>───────────<br/>/policyType"]
        EV["events<br/>───────────<br/>/eventDate"]
        A["audit<br/>───────────<br/>/auditDate<br/>NO TTL"]
    end

    subgraph CosmosGremlin["Cosmos DB Gremlin API"]
        G["EntraGraph/graph<br/>───────────<br/>/pk (tenantId)"]
    end

    subgraph Snapshots["Blob Snapshots"]
        DOT["snapshots/*.dot"]
        JSON["snapshots/*.json"]
        MAN["snapshots/manifest.json"]
    end

    PRIN --> P
    RES --> R
    EDGE --> E
    POL --> PO
    EVT --> EV

    P -.->|"delta"| A
    R -.->|"delta"| A
    E -.->|"delta"| A
    PO -.->|"delta"| A

    A -->|"project"| G
    G -->|"query"| DOT
    G -->|"query"| JSON
```

| Container | Partition Key | Contents | TTL |
|-----------|---------------|----------|-----|
| `principals` | `/objectId` | Users, Groups, Service Principals, Devices | None |
| `resources` | `/resourceType` | Applications, Role Definitions, Tenant, Subscriptions, RGs, Key Vaults, VMs, Automation Accounts, Function Apps, Logic Apps, Web Apps | None |
| `edges` | `/edgeType` | ALL relationships unified (Entra + Azure + CA Policy + Role Policy) | None |
| `policies` | `/policyType` | CA policies, role management policies, named locations | None |
| `events` | `/eventDate` | Sign-ins, audits | 90 days |
| `audit` | `/auditDate` | Unified change log - **NO TTL** (permanent history) | None |
| `EntraGraph/graph` | `/pk` (tenantId) | Gremlin vertices and edges | None |

### Type Discriminators

Every document includes a type discriminator field:

| Container | Discriminator | Values |
|-----------|---------------|--------|
| `principals` | `principalType` | `user`, `group`, `servicePrincipal`, `device` |
| `resources` | `resourceType` | `application`, `directoryRoleDefinition`, `azureRoleDefinition`, `tenant`, `managementGroup`, `subscription`, `resourceGroup`, `keyVault`, `virtualMachine`, `automationAccount`, `functionApp`, `logicApp`, `webApp` |
| `edges` | `edgeType` | `groupMember`, `directoryRole`, `pimEligible`, `azureRbac`, `hasManagedIdentity`, `caPolicyTargetsPrincipal`, `rolePolicyAssignment`, ... (24 types) |
| `policies` | `policyType` | `conditionalAccess`, `roleManagement`, `namedLocation` |
| `events` | `eventType` | `signIn`, `audit` |

### Blob Structure

```
raw-data/{timestamp}/
├── {timestamp}-principals.jsonl    ← Users, Groups, SPs, Devices
├── {timestamp}-resources.jsonl     ← Apps + Role Definitions + ALL Azure resources
├── {timestamp}-edges.jsonl         ← ALL relationships unified (incl. CA/PIM edges)
├── {timestamp}-policies.jsonl
├── {timestamp}-events.jsonl
└── snapshots/
    ├── manifest.json
    ├── paths-to-global-admin.json
    ├── paths-to-global-admin.dot
    ├── dangerous-service-principals.json
    ├── dangerous-service-principals.dot
    └── ...
```

---

## Collectors

### Principal Collectors (4)

| Collector | Output | principalType | Key Fields |
|-----------|--------|---------------|------------|
| `CollectUsersWithAuthMethods` | principals.jsonl | `user` | UPN, MFA state, auth methods, sign-in activity |
| `CollectEntraGroups` | principals.jsonl | `group` | Security/mail enabled, membership rule, member counts |
| `CollectEntraServicePrincipals` | principals.jsonl | `servicePrincipal` | App ID, SP type, credentials, OAuth scopes |
| `CollectDevices` | principals.jsonl | `device` | OS, compliance, trust type, last sign-in |

### Resource Collectors (10)

| Collector | Output | resourceType | Key Fields |
|-----------|--------|--------------|------------|
| `CollectAppRegistrations` | resources.jsonl | `application` | API permissions, federated credentials, publisher |
| `CollectDirectoryRoleDefinitions` | resources.jsonl | `directoryRoleDefinition` | Role template ID, isPrivileged, permissions |
| `CollectAzureRoleDefinitions` | resources.jsonl | `azureRoleDefinition` | Role name, isBuiltIn, isPrivileged, permissions |
| `CollectAzureHierarchy` | resources.jsonl, edges.jsonl | `tenant`, `managementGroup`, `subscription`, `resourceGroup` | Hierarchy containment |
| `CollectKeyVaults` | resources.jsonl, edges.jsonl | `keyVault` | Access policies, RBAC, soft delete, network rules |
| `CollectVirtualMachines` | resources.jsonl, edges.jsonl | `virtualMachine` | Managed identity, power state, OS, network |
| `CollectAutomationAccounts` | resources.jsonl, edges.jsonl | `automationAccount` | Managed identity, local auth, runbooks |
| `CollectFunctionApps` | resources.jsonl, edges.jsonl | `functionApp` | Managed identity, HTTPS, auth settings |
| `CollectLogicApps` | resources.jsonl, edges.jsonl | `logicApp` | Managed identity, triggers, actions |
| `CollectWebApps` | resources.jsonl, edges.jsonl | `webApp` | Managed identity, HTTPS, client certs |

### Other Collectors (3)

| Collector | Output | Notes |
|-----------|--------|-------|
| `CollectRelationships` | edges.jsonl | All Entra relationships (21 edge types incl. CA/PIM policy edges) |
| `CollectPolicies` | policies.jsonl | CA policies, role policies, named locations |
| `CollectEvents` | events.jsonl | Sign-ins, audit logs |

---

## Edge Types (24 total)

### Entra Edges (15 types)

| edgeType | Source | Target | API |
|----------|--------|--------|-----|
| `groupMember` | user/group/SP/device | group | `/groups/{id}/members` |
| `groupMemberTransitive` | user | group | `/groups/{id}/transitiveMembers` |
| `groupOwner` | user | group | `/groups/{id}/owners` |
| `directoryRole` | user/group/SP | role | `/roleManagement/directory/roleAssignments` |
| `pimEligible` | user/group | role | `/roleManagement/directory/roleEligibilitySchedules` |
| `pimActive` | user/group | role | `/roleManagement/directory/roleAssignmentSchedules` |
| `pimGroupEligible` | user | group | `/identityGovernance/privilegedAccess/group/eligibilitySchedules` |
| `pimGroupActive` | user | group | `/identityGovernance/privilegedAccess/group/assignmentSchedules` |
| `azureRbac` | user/group/SP | azureRole | Azure RM API |
| `appRoleAssignment` | user/group/SP | SP | `/servicePrincipals/{id}/appRoleAssignedTo` |
| `oauth2PermissionGrant` | user/tenant | SP | `/oauth2PermissionGrants` |
| `license` | user | license | `/users/{id}/licenseDetails` |
| `deviceOwner` | user | device | `/devices/{id}/registeredOwners` |
| `appOwner` | user/SP | application | `/applications/{id}/owners` |
| `spOwner` | user/SP | servicePrincipal | `/servicePrincipals/{id}/owners` |

### Azure Edges (3 types)

| edgeType | Source | Target | Description |
|----------|--------|--------|-------------|
| `contains` | MG/Sub/RG | Child resource | Azure hierarchy containment |
| `keyVaultAccess` | principal | keyVault | Access policy permissions (get/set secrets, keys, certs) |
| `hasManagedIdentity` | Azure resource | servicePrincipal | System or user-assigned managed identity link |

### Conditional Access Policy Edges (5 types) - NEW in V3.5

| edgeType | Source | Target | Description |
|----------|--------|--------|-------------|
| `caPolicyTargetsPrincipal` | CA Policy | User/Group/Role | Policy applies to this principal |
| `caPolicyExcludesPrincipal` | CA Policy | User/Group/Role | Principal excluded (bypass) from policy |
| `caPolicyTargetsApplication` | CA Policy | App/SP | Policy applies to this application |
| `caPolicyExcludesApplication` | CA Policy | App/SP | Application excluded from policy |
| `caPolicyUsesLocation` | CA Policy | Named Location | Policy references this location condition |

### Role Management Policy Edges (1 type) - NEW in V3.5

| edgeType | Source | Target | Description |
|----------|--------|--------|-------------|
| `rolePolicyAssignment` | Role Mgmt Policy | Directory Role | PIM policy assigned to role |

---

## Edge Properties

### CA Policy Edge Properties

```json
{
  "id": "{policyId}_{targetId}_{edgeType}",
  "edgeType": "caPolicyTargetsPrincipal",
  "sourceId": "ca-policy-guid",
  "sourceType": "conditionalAccessPolicy",
  "sourceDisplayName": "Require MFA for all users",
  "targetId": "user-or-group-guid",
  "targetType": "user | group | allUsers | allGuestUsers | directoryRole",
  "targetDisplayName": "Engineering Team",
  "policyState": "enabled | disabled | enabledForReportingButNotEnforced",
  "requiresMfa": true,
  "blocksAccess": false,
  "requiresCompliantDevice": false,
  "requiresHybridAzureADJoin": false,
  "requiresApprovedApp": false,
  "requiresAppProtection": false,
  "clientAppTypes": ["browser", "mobileAppsAndDesktopClients"],
  "hasLocationCondition": true,
  "hasRiskCondition": false,
  "effectiveFrom": "ISO-8601",
  "effectiveTo": null,
  "collectionTimestamp": "ISO-8601"
}
```

### Role Policy Edge Properties

```json
{
  "id": "{policyId}_{roleDefinitionId}_rolePolicyAssignment",
  "edgeType": "rolePolicyAssignment",
  "sourceId": "role-mgmt-policy-guid",
  "sourceType": "roleManagementPolicy",
  "sourceDisplayName": "Global Administrator Policy",
  "targetId": "62e90394-69f5-4237-9190-012177145e10",
  "targetType": "directoryRole",
  "targetDisplayName": "Global Administrator",
  "requiresMfaOnActivation": true,
  "requiresApproval": true,
  "requiresJustification": true,
  "requiresTicketInfo": false,
  "maxActivationDurationHours": 8,
  "permanentAssignmentAllowed": false,
  "eligibleAssignmentMaxDurationDays": 365,
  "effectiveFrom": "ISO-8601",
  "effectiveTo": null,
  "collectionTimestamp": "ISO-8601"
}
```

---

## Synthetic Vertices (Role Definitions)

V3.5 adds role definitions as first-class vertices in the graph, enabling attack path queries through roles.

### Directory Role Definition

```json
{
  "id": "{roleDefinitionId}",
  "objectId": "{roleDefinitionId}",
  "resourceType": "directoryRoleDefinition",
  "displayName": "Global Administrator",
  "description": "Can manage all aspects of Azure AD and Microsoft services...",
  "roleTemplateId": "62e90394-69f5-4237-9190-012177145e10",
  "isBuiltIn": true,
  "isEnabled": true,
  "isPrivileged": true,
  "rolePermissions": [...],
  "effectiveFrom": "ISO-8601",
  "effectiveTo": null,
  "collectionTimestamp": "ISO-8601"
}
```

### Azure Role Definition

```json
{
  "id": "{roleDefinitionId}",
  "objectId": "{roleDefinitionId}",
  "resourceType": "azureRoleDefinition",
  "displayName": "Contributor",
  "description": "Grants full access to manage all resources...",
  "roleName": "Contributor",
  "roleType": "BuiltInRole",
  "isBuiltIn": true,
  "isPrivileged": true,
  "permissions": [...],
  "assignableScopes": ["/"],
  "effectiveFrom": "ISO-8601",
  "effectiveTo": null,
  "collectionTimestamp": "ISO-8601"
}
```

### Privileged Role Detection

| Type | Privileged Role Template IDs / Names |
|------|--------------------------------------|
| **Entra Roles** | Global Administrator, Privileged Role Administrator, Security Administrator, Application Administrator, Cloud Application Administrator, Privileged Authentication Administrator, User Administrator, Exchange Administrator, SharePoint Administrator, Password Administrator |
| **Azure Roles** | Owner, Contributor, User Access Administrator, Virtual Machine Contributor, Key Vault Administrator, Key Vault Secrets Officer, Storage Account Contributor, Automation Contributor |

---

## Indexers (5)

| Indexer | Input | Output Container | Partition Key |
|---------|-------|------------------|---------------|
| `IndexPrincipalsInCosmosDB` | principals.jsonl | principals | /objectId |
| `IndexResourcesInCosmosDB` | resources.jsonl | resources | /resourceType |
| `IndexEdgesInCosmosDB` | edges.jsonl | edges | /edgeType |
| `IndexPoliciesInCosmosDB` | policies.jsonl | policies | /policyType |
| `IndexEventsInCosmosDB` | events.jsonl | events | /eventDate |

All indexers write change records to the `audit` container (partitioned by `/auditDate`).

---

## Gremlin Graph Projection

### Architecture

The `ProjectGraphToGremlin` function runs every 15 minutes to sync changes from the audit container to the Gremlin graph database.

```mermaid
flowchart LR
    subgraph Cosmos["Cosmos DB SQL API"]
        Audit["audit container<br/>(change records)"]
    end

    subgraph Projector["ProjectGraphToGremlin"]
        WM["Read watermark"]
        QA["Query audit changes"]
        PV["Project vertices"]
        PE["Project edges"]
        UW["Update watermark"]
    end

    subgraph Gremlin["Cosmos DB Gremlin API"]
        Graph["EntraGraph/graph"]
    end

    WM --> QA
    Audit --> QA
    QA --> PV
    PV --> Graph
    PV --> PE
    PE --> Graph
    PE --> UW
```

### Gremlin Data Model

**Vertices:**
- `id`: objectId
- `label`: principalType or resourceType (user, group, servicePrincipal, directoryRoleDefinition, etc.)
- `pk`: tenantId (partition key)
- `displayName`: display name

**Edges:**
- `id`: sourceId_targetId_edgeType
- `label`: edgeType (groupMember, directoryRole, caPolicyTargetsPrincipal, etc.)
- Edge properties copied from edges container

### Upsert Pattern

Uses Gremlin `fold().coalesce()` pattern for idempotent operations:

```gremlin
// Vertex upsert
g.V('object-id')
  .fold()
  .coalesce(
    unfold(),
    addV('user').property(id, 'object-id').property('pk', 'tenant-id')
  )

// Edge upsert
g.V('source-id')
  .coalesce(
    outE('edgeType').where(inV().hasId('target-id')),
    addE('edgeType').to(g.V('target-id'))
  )
```

---

## Attack Path Snapshots

### Architecture

The `GenerateGraphSnapshots` function runs hourly to generate pre-computed attack path snapshots.

### Snapshot Types

| Snapshot | Gremlin Query | Purpose |
|----------|---------------|---------|
| `paths-to-global-admin` | `g.V().hasLabel('directoryRoleDefinition').has('roleTemplateId','62e90394...').repeat(__.in().simplePath()).emit().limit(50).path()` | All paths leading to Global Admin role |
| `dangerous-service-principals` | `g.V().hasLabel('servicePrincipal').where(out('hasRole').hasLabel('directoryRoleDefinition').has('isPrivileged',true)).limit(30).path()` | SPs with privileged roles |
| `external-user-exposure` | `g.V().has('userType','Guest').repeat(out().simplePath()).until(hasLabel('directoryRoleDefinition').has('isPrivileged',true)).limit(30).path()` | Guest users with paths to privileged roles |
| `mfa-coverage-gaps` | `g.V().hasLabel('user','group').where(inE('caPolicyExcludesPrincipal').has('requiresMfa',true)).limit(50)` | Principals excluded from MFA policies |
| `pim-activation-risks` | `g.E().hasLabel('rolePolicyAssignment').has('requiresMfaOnActivation',false).limit(50)` | Roles without MFA on activation |
| `group-nested-paths` | `g.V().hasLabel('group').repeat(out('memberOf').simplePath()).emit().times(4).path().limit(30)` | Deep group nesting |
| `app-to-privileged-role` | `g.V().hasLabel('application').out('hasServicePrincipal').where(out('hasRole').hasLabel('directoryRoleDefinition').has('isPrivileged',true)).limit(30).path()` | Apps with privileged SPs |

### Output Format

Each snapshot generates:

1. **JSON file** (`{snapshot-name}.json`):
```json
{
  "name": "paths-to-global-admin",
  "title": "Attack Paths to Global Administrator",
  "description": "Paths from any principal to Global Administrator role",
  "timestamp": "2026-01-08T14-00-00Z",
  "pathCount": 15,
  "paths": [...]
}
```

2. **DOT file** (`{snapshot-name}.dot`):
```dot
digraph "paths-to-global-admin" {
  rankdir=LR;
  node [shape=box, style=filled];
  label="Attack Paths to Global Administrator";

  user_abc [label="John Doe", fillcolor="#E3F2FD"];
  group_xyz [label="IT Admins", fillcolor="#E8F5E9"];
  role_gbl [label="Global Administrator", fillcolor="#FFEBEE"];

  user_abc -> group_xyz;
  group_xyz -> role_gbl;
}
```

3. **Manifest** (`manifest.json`):
```json
{
  "generatedAt": "2026-01-08T14-00-00Z",
  "snapshotCount": 7,
  "totalPaths": 42,
  "errors": 0,
  "snapshots": [
    { "name": "paths-to-global-admin", "title": "...", "pathCount": 15 },
    ...
  ]
}
```

---

## Temporal Fields

V3.5 retains temporal tracking on all entities and edges:

```json
{
  "objectId": "user-guid",
  "displayName": "John Doe",
  "effectiveFrom": "2026-01-01T00:00:00Z",
  "effectiveTo": null,
  ...
}
```

| Field | Description |
|-------|-------------|
| `effectiveFrom` | Timestamp when entity was first seen (or re-appeared) |
| `effectiveTo` | Timestamp when entity was deleted (`null` = current/active) |

This enables point-in-time queries:
```sql
-- All users that were active on a specific date
SELECT * FROM principals p
WHERE p.principalType = 'user'
  AND p.effectiveFrom <= '2026-01-15T00:00:00Z'
  AND (p.effectiveTo IS NULL OR p.effectiveTo > '2026-01-15T00:00:00Z')
```

---

## Example Queries

### Cosmos DB SQL Queries

#### "All users with no MFA registered"
```sql
SELECT * FROM principals p
WHERE p.principalType = 'user'
  AND p.authMethodCount <= 1
  AND p.effectiveTo = null
```

#### "Principals excluded from MFA policies"
```sql
SELECT e.targetDisplayName, e.sourceDisplayName as policyName
FROM edges e
WHERE e.edgeType = 'caPolicyExcludesPrincipal'
  AND e.requiresMfa = true
  AND e.effectiveTo = null
```

#### "Roles without MFA on PIM activation"
```sql
SELECT e.targetDisplayName as roleName, e.maxActivationDurationHours
FROM edges e
WHERE e.edgeType = 'rolePolicyAssignment'
  AND e.requiresMfaOnActivation = false
  AND e.effectiveTo = null
```

#### "Privileged directory role definitions"
```sql
SELECT r.displayName, r.roleTemplateId
FROM resources r
WHERE r.resourceType = 'directoryRoleDefinition'
  AND r.isPrivileged = true
```

### Gremlin Graph Queries

#### "Who can reach Global Admin?"
```gremlin
g.V().hasLabel('directoryRoleDefinition').has('roleTemplateId', '62e90394-69f5-4237-9190-012177145e10')
  .repeat(__.in()).emit().path()
```

#### "What can this compromised user access?"
```gremlin
g.V('user-id').repeat(out()).emit().path()
```

#### "Attack path: User → Group → VM → Managed Identity → KeyVault"
```gremlin
g.V('user-id').out('groupMember').out('azureRbac').out('hasManagedIdentity').out('keyVaultAccess')
```

#### "Service principals excluded from MFA policies"
```gremlin
g.V().hasLabel('servicePrincipal')
  .where(inE('caPolicyExcludesPrincipal').has('requiresMfa', true))
```

#### "Roles that can be activated without MFA"
```gremlin
g.E().hasLabel('rolePolicyAssignment')
  .has('requiresMfaOnActivation', false)
  .inV()
```

---

## Summary

| Aspect | Value |
|--------|-------|
| Collectors | 17 (4 Principal + 10 Resource + 3 Other) |
| Indexers | 5 |
| Graph Functions | 2 (Gremlin Projector + Snapshot Generator) |
| Cosmos SQL containers | 6 |
| Cosmos Gremlin container | 1 |
| Edge types | 24 (15 Entra + 3 Azure + 5 CA Policy + 1 Role Policy) |
| Resource types | 13 (application, 2 role defs, tenant, MG, sub, RG, KV, VM, automation, function, logic, web) |
| Principal types | 4 (user, group, servicePrincipal, device) |
| Blob files per run | 5 (principals, resources, edges, policies, events) |
| Snapshot types | 7 attack path patterns |
| Partition strategy | principalType/resourceType/edgeType for efficient queries |
| Delta detection | ~99% write reduction |
| Historical tracking | Permanent (no TTL on audit container) |
| Temporal fields | effectiveFrom/effectiveTo on all entities |
| Gremlin sync | Every 15 minutes from audit container |
| Snapshot generation | Hourly |

### Key Architectural Decisions (V3.5)

1. **Applications are resources, not principals** - Semantic correctness
2. **Unified edges container** - All relationships in one place for graph queries
3. **Unified resources container** - Apps + Azure resources + Role definitions together
4. **Temporal fields** - Enable point-in-time queries
5. **Append blob with If-None-Match** - Race-safe parallel writes to same file
6. **roleManagement API** - Consistent, includes custom roles
7. **Gremlin projection from audit** - Changes sync to graph via audit container
8. **Separate Gremlin Cosmos account** - SQL and Gremlin APIs require separate accounts
9. **CA/PIM policy edges** - Security policy coverage as graph relationships
10. **Role definitions as vertices** - Enables path traversal through roles
11. **Attack path snapshots** - Pre-computed common attack patterns
12. **DOT format output** - Standard format for graph visualization tools

---

**End of Architecture Document**
