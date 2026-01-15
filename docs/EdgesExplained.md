# Edge Collection and Derivation - Solution Explained

This document explains what the edge collection and derivation system does in this solution.

---

## Part 1: What the Current Solution Does

### Overview

The solution collects identity relationships from Microsoft Entra ID and Azure, then derives "attack capability" edges that show what each identity can actually do. This enables attack path analysis similar to BloodHound.

**Data Flow:**
```
Microsoft Graph/Azure APIs
        │
        ▼
┌─────────────────────────┐
│  CollectRelationships   │  ← Collects raw edges (who has what)
│      (14 phases)        │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│      Cosmos DB          │  ← Stores all edges
│    (edges container)    │
└───────────┬─────────────┘
            │
    ┌───────┴───────┐
    ▼               ▼
┌─────────┐   ┌─────────────────┐
│ Derive  │   │ DeriveVirtual   │
│ Edges   │   │ Edges           │
└────┬────┘   └────────┬────────┘
     │                 │
     └────────┬────────┘
              ▼
┌─────────────────────────┐
│  ProjectGraphToGremlin  │  ← Syncs to graph database
└─────────────────────────┘
              │
              ▼
┌─────────────────────────┐
│     Gremlin Graph       │  ← Attack path queries run here
└─────────────────────────┘
```

---

### Step 1: CollectRelationships (Raw Edge Collection)

**File:** `FunctionApp/CollectRelationships/run.ps1`

This function queries Microsoft Graph and Azure APIs to collect all identity relationships. It runs 14 phases, each collecting a specific type of relationship.

#### What It Collects

| Phase | Edge Type | What It Represents | Example |
|-------|-----------|-------------------|---------|
| 1 | `groupMember` | Direct group membership | "Alice is a member of Sales-Team" |
| 1b | `groupMemberTransitive` | Nested group membership | "Alice is in Sales-Team which is in All-Employees" |
| 2 | `directoryRole` | Entra ID role assignment | "Bob has User Administrator role" |
| 3 | `pimEligible` | PIM eligible assignment | "Carol can activate Global Admin" |
| 3 | `pimActive` | PIM active assignment | "Carol currently has Global Admin active" |
| 3b | `pimRequest` | PIM activation request | "Carol activated Global Admin with justification X" |
| 4 | `pimGroupEligible/Active` | PIM for role-assignable groups | "Dave can activate membership in Tier0-Admins group" |
| 5 | `azureRbac` | Azure subscription roles | "ServicePrincipal-X has Owner on Subscription-Prod" |
| 6 | `appOwner` | Application ownership | "Eve owns the HR-App application" |
| 7 | `spOwner` | Service principal ownership | "Eve owns the HR-App service principal" |
| 8 | `license` | License assignment | "Frank has E5 license" |
| 9 | `oauth2PermissionGrant` | Delegated permission consent | "User consented App-X to read their mail" |
| 10 | `appRoleAssignment` | Application permission grant | "App-X has Application.ReadWrite.All on Graph" |
| 11 | `groupOwner` | Group ownership | "Grace owns the Finance-Team group" |
| 12 | `deviceOwner` | Device ownership | "Henry owns device YOURPC01" |
| 13 | `caPolicy*` | Conditional Access targeting | "CA-RequireMFA policy targets All-Users group" |
| 14 | `rolePolicyAssignment` | PIM policy settings | "Global Admin role requires MFA to activate" |

#### Key Technical Details

- Uses Microsoft Graph `$batch` API for performance (20 requests per batch = 3x faster)
- Handles pagination for large groups (>100 members)
- Outputs to a single `edges.jsonl` blob file
- All edges share a timestamp from the orchestrator

#### What the Raw Edges Tell You

Raw edges answer: **"What relationships exist?"**

Example raw edge:
```json
{
  "edgeType": "appRoleAssignment",
  "sourceId": "sp-12345",
  "targetId": "microsoft-graph-sp",
  "appRoleId": "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9",
  "appRoleDisplayName": "Application.ReadWrite.All"
}
```

This tells you: Service Principal sp-12345 has the Application.ReadWrite.All permission on Microsoft Graph.

**But it doesn't tell you:** What can sp-12345 actually DO with that permission?

---

### Step 2: DeriveEdges (Attack Capability Derivation)

**File:** `FunctionApp/DeriveEdges/run.ps1`

This function reads the raw edges and creates NEW edges that represent attack capabilities. It translates "what you have" into "what you can do."

#### How It Works

1. Reads raw edges from Cosmos DB
2. Cross-references against `DangerousPermissions.psd1` (a lookup table)
3. Creates derived edges with semantic meaning

#### What It Derives

**From Graph Permissions (appRoleAssignment edges):**

| If you have this permission... | You get this derived edge | Meaning |
|-------------------------------|---------------------------|---------|
| `Application.ReadWrite.All` | `canAddSecretToAnyApp` | Can add credentials to any app, then authenticate as it |
| `RoleManagement.ReadWrite.Directory` | `canAssignAnyRole` | Can make anyone a Global Admin |
| `Group.ReadWrite.All` | `canModifyAnyGroup` | Can add yourself to any group |
| `GroupMember.ReadWrite.All` | `canAddMemberToAnyGroup` | Can add anyone to any group |
| `AppRoleAssignment.ReadWrite.All` | `canGrantAnyPermission` | Can grant any API permission to any app |

**From Directory Roles (directoryRole edges):**

| If you have this role... | You get these derived edges | Tier |
|-------------------------|----------------------------|------|
| Global Administrator | `isGlobalAdmin`, `canDoEverything` | 0 |
| Privileged Role Administrator | `canAssignAnyRole`, `canManagePIM` | 0 |
| Application Administrator | `canAddSecretToAnyApp`, `canModifyAnyApp` | 0 |
| User Administrator | `canModifyAnyUser`, `canResetNonAdminPasswords` | 1 |
| Groups Administrator | `canModifyAnyGroup`, `canAddMemberToAnyGroup` | 1 |

**From Ownership (appOwner/spOwner/groupOwner edges):**

| If you own... | You get this derived edge | Why it matters |
|--------------|--------------------------|----------------|
| An application | `canAddSecret` (to that app) | Can add credentials and authenticate as the app |
| A service principal | `canAddSecret` (to that SP) | Same as above |
| A group | `canModifyGroup` | Can add/remove members |
| A role-assignable group | `canAssignRolesViaGroup` | Adding members to this group grants them roles |

**From Azure RBAC (azureRbac edges):**

| If you have this Azure role... | You get this derived edge |
|-------------------------------|---------------------------|
| Owner | `azureOwner` |
| User Access Administrator | `canAssignAzureRoles` |
| Virtual Machine Contributor | `canRunCodeOnVMs` |
| Key Vault Administrator | `keyVaultAdmin` |
| Automation Contributor | `canRunRunbooks` |

#### What the Derived Edges Tell You

Derived edges answer: **"What can this identity actually do?"**

Example derived edge:
```json
{
  "edgeType": "canAddSecretToAnyApp",
  "sourceId": "sp-12345",
  "targetId": "allApps",
  "severity": "Critical",
  "derivedFrom": "appRoleAssignment",
  "permissionName": "Application.ReadWrite.All"
}
```

This tells you: Service Principal sp-12345 can add credentials to ANY application in the tenant.

---

### Step 3: DeriveVirtualEdges (Policy Gate Edges)

**File:** `FunctionApp/DeriveVirtualEdges/run.ps1`

This creates edges showing which Intune policies target which groups.

| Edge Type | What It Represents |
|-----------|-------------------|
| `compliancePolicyTargets` | "Compliance policy X targets group Y" |
| `compliancePolicyExcludes` | "Compliance policy X excludes group Y" |
| `appProtectionPolicyTargets` | "App protection policy X targets group Y" |
| `appProtectionPolicyExcludes` | "App protection policy X excludes group Y" |

**Why this matters:** If you compromise a group that's excluded from compliance policies, you might bypass security controls.

---

### Step 4: ProjectGraphToGremlin (Graph Database Sync)

**File:** `FunctionApp/ProjectGraphToGremlin/run.ps1`

This syncs all edges (raw + derived) to a Gremlin graph database for querying.

- Runs every 15 minutes (timer trigger)
- Uses watermark-based incremental sync
- Processes vertices first (users, groups, apps), then edges
- Handles creates, updates, and deletes

---

### How Attack Path Queries Work

Once everything is in Gremlin, you can query attack paths:

```groovy
// "Show me all paths from compromised-user to Global Admin"
g.V().has('id', 'compromised-user')
  .repeat(out().simplePath())
  .until(has('edgeType', 'isGlobalAdmin'))
  .path()

// "Who can add secrets to any app?" (Tier 0 risk)
g.E().has('edgeType', 'canAddSecretToAnyApp')
  .outV()
  .valueMap('displayName', 'userPrincipalName')

// "What's the blast radius if this service principal is compromised?"
g.V().has('id', 'sp-12345')
  .repeat(out().simplePath())
  .emit()
  .dedup()
  .count()
```

---

### Summary: Current Solution

| Component | Purpose | Input | Output |
|-----------|---------|-------|--------|
| CollectRelationships | Gather raw relationships | Graph/Azure APIs | Raw edges (who has what) |
| DeriveEdges | Compute attack capabilities | Raw edges + DangerousPermissions.psd1 | Derived edges (who can do what) |
| DeriveVirtualEdges | Map policy targeting | Intune policies | Policy gate edges |
| ProjectGraphToGremlin | Enable graph queries | All edges | Gremlin graph database |

---

## Part 2: What Changes With Epic v4

Epic v4 (`docs/Epic v4 - edges-v4.md`) proposes two changes:

### Change A: Schema Refactoring (Nested Properties)

**Current (Flat):**
```json
{
  "id": "user123_group456_groupMember",
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "group456",
  "sourceDisplayName": "John Doe",
  "targetDisplayName": "Sales Team",
  "membershipType": "Direct",
  "severity": null,
  "tier": null,
  "subscriptionId": null,
  "requiresMfa": null
}
```

**Proposed (Nested):**
```json
{
  "id": "user123_group456_groupMember",
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "group456",
  "schemaVersion": 2,
  "properties": {
    "sourceDisplayName": "John Doe",
    "targetDisplayName": "Sales Team",
    "membershipType": "Direct"
  }
}
```

**Why:** The current schema has 87+ fields at the root level, with ~70% being null for any given edge. This wastes storage and makes the data harder to understand.

**Impact:**
- Storage: Reduced document size (no null fields)
- Queries: Need to update from `c.sourceDisplayName` to `c.properties.sourceDisplayName`
- Gremlin: No change (properties are flattened during projection)

---

### Change B: Security Enrichment

**Current:** Only derived edges have `tier` and `severity`. Raw edges don't have security context.

**Proposed:** Add security metadata to raw edges:

| New Field | What It Means | Source |
|-----------|--------------|--------|
| `mfaProtected` | "Is this edge protected by MFA?" | Correlate with CA policies |
| `tier` | "How critical is the target?" | Role template classification |
| `severity` | "How risky is this relationship?" | Tier + edge type heuristics |

**Example enriched edge:**
```json
{
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "tier0-admins-group",
  "properties": {
    "mfaProtected": true,
    "tier": 0,
    "severity": "Critical"
  }
}
```

**Why:** Currently, to know if a group membership requires MFA, you need to:
1. Find all CA policies
2. Check which ones require MFA
3. Check if they target this group

With enrichment, that's pre-computed on the edge itself.

**New Function Required:** `EnrichEdges/run.ps1` - runs after collection, correlates edges with CA policies.

---

### Summary: What Epic v4 Changes

| Aspect | Current | After Epic v4 |
|--------|---------|---------------|
| Document structure | 87+ flat fields, many null | Core fields + nested properties object |
| Null handling | Stored explicitly | Omitted entirely |
| Security context on raw edges | None | `mfaProtected`, `tier`, `severity` |
| CA policy correlation | Manual query required | Pre-computed on edge |
| Gremlin queries | Work as-is | No change (flattened at projection) |
| Dashboard queries | `c.fieldName` | `c.properties.fieldName` |

---

## Quick Reference: Edge Types

### Raw Edges (CollectRelationships)

| Edge Type | Source → Target | Key Question Answered |
|-----------|----------------|----------------------|
| `groupMember` | identity → group | "Who is in this group?" |
| `groupMemberTransitive` | identity → group | "Who is in this group (including nested)?" |
| `directoryRole` | identity → role | "Who has this Entra role?" |
| `pimEligible` | identity → role | "Who can activate this role?" |
| `pimActive` | identity → role | "Who has this role active now?" |
| `azureRbac` | identity → Azure role | "Who has this Azure role on this scope?" |
| `appOwner` | identity → app | "Who owns this application?" |
| `spOwner` | identity → SP | "Who owns this service principal?" |
| `groupOwner` | identity → group | "Who owns this group?" |
| `appRoleAssignment` | identity → resource SP | "What API permissions does this identity have?" |
| `oauth2PermissionGrant` | user → resource SP | "What delegated permissions were consented?" |
| `caPolicyTargetsPrincipal` | policy → identity | "Who does this CA policy apply to?" |
| `rolePolicyAssignment` | policy → role | "What PIM settings apply to this role?" |

### Derived Edges (DeriveEdges)

| Edge Type | What It Means | Severity |
|-----------|--------------|----------|
| `isGlobalAdmin` | Has Global Admin role | Critical |
| `canAssignAnyRole` | Can make anyone any role | Critical |
| `canAddSecretToAnyApp` | Can compromise any app | Critical |
| `canModifyAnyGroup` | Can add self to any group | High |
| `canResetAnyPassword` | Can take over any account | High |
| `canAddSecret` | Can compromise a specific app/SP | High |
| `canModifyGroup` | Can modify a specific group | Medium |
| `azureOwner` | Has Owner on Azure scope | Critical |
| `canRunCodeOnVMs` | Can execute code on VMs | High |

### Virtual Edges (DeriveVirtualEdges)

| Edge Type | What It Means |
|-----------|--------------|
| `compliancePolicyTargets` | Policy applies to this group |
| `compliancePolicyExcludes` | Policy excludes this group |
| `appProtectionPolicyTargets` | App protection applies to this group |
| `appProtectionPolicyExcludes` | App protection excludes this group |
