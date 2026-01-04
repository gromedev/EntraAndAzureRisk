```markdown
Below is a **concrete, end-to-end recommendation** for how to leverage **Azure AI Foundry specifically for dashboard output**, aligned to the architecture you described and without re-litigating earlier points.

This is written as an **implementation guide**, not theory.

---

## 1. First principle (dashboard-driven design)

Your dashboard dictates everything.

Therefore:

* Foundry **does not** drive workflow
* Foundry **does not** drive discovery
* Foundry **does not** drive joins
* Foundry **does** drive **final representation and scoring**

Foundry’s only durable output is:

> **Rows in a dashboard-optimized “findings” dataset**

---

## 2. Add a dedicated “Findings” layer

Introduce a new persistence layer that **only Foundry writes to**.

### New Cosmos container (or table)

```
findings
```

Partition key:

```
/analysisType
```

Each document = **one dashboard row**

No nested blobs. No raw records.

---

## 3. Revised execution flow (with Foundry)

```
Trigger
  ↓
Orchestrator
  ↓
Collection + Indexing (unchanged)
  ↓
Detectors (code, deterministic)
  ↓
Candidate Findings (materialized)
  ↓
Foundry Evaluation
  ↓
Findings Container
  ↓
Dashboard (read-only)
```

Foundry is **after** detection and **before** presentation.

---

## 4. What your Function App sends to Foundry

Your detectors already know:

* principal
* path
* role / license / privilege
* scope
* timestamps
* snapshotId

You send **one candidate at a time**.

This is important:

* single input → single output
* no batching
* no aggregation

---

## 5. What Foundry produces (dashboard contract)

Foundry produces a **normalized finding record**.

This record is:

* flat
* stable
* sortable
* filterable
* renderable without transformation

### Canonical “finding” shape

```
{
  "findingId": "uuid",
  "analysisType": "privilege_escalation_dynamic_group",
  "detectedAt": "2026-01-03T12:02:10Z",

  "principalKind": "user",
  "principalId": "user-111",

  "effectivePrivilege": "Compliance Administrator",
  "privilegeScope": "/subscriptions/...",

  "pathDepth": 4,
  "riskClass": "identity_privilege_escalation",

  "confidence": 0.95,
  "severity": 8,

  "status": "confirmed",

  "remediationAction": "remove_role_assignment",
  "remediationCommand": "az role assignment delete ...",

  "snapshotId": "snap-2026-01-03-1200"
}
```

This is the **dashboard schema**.
Not the AI schema.

---

## 6. Why Foundry is useful *here*

### Foundry does things your code should not hard-code:

1. **Severity normalization**

   * Different detectors produce comparable severity
   * A “7” means the same thing everywhere

2. **Confidence calibration**

   * Rule-based vs inferred cases
   * Dynamic group vs explicit assignment
   * Recent vs old change

3. **Risk classification**

   * `identity_privilege_escalation`
   * `rbac_excess`
   * `cost_exposure`
   * `governance_gap`

4. **Remediation synthesis**

   * Produces *consistent* commands
   * Enforces least-privilege defaults
   * Keeps logic out of UI and detectors

These are **policy-level concerns**, not data-engineering tasks.

---

## 7. What Foundry must NOT emit

Foundry output must **never** contain:

* Raw directory objects
* Group membership arrays
* JSON snippets
* Cosmos queries
* Explanatory prose
* Variable schemas

Those belong to:

* audit logs
* drill-down APIs
* offline analysis

---

## 8. Dashboard consumption pattern

Your dashboard reads **only** from `findings`.

Typical queries:

* All findings with severity ≥ 7
* Findings by riskClass
* Findings introduced since last snapshot
* Findings affecting a given principalId
* Findings grouped by analysisType

No joins.
No interpretation.
No AI logic in the UI.

---

## 9. Drill-down (optional, but clean)

When a user clicks a row:

1. Dashboard calls:

   ```
   GET /findings/{findingId}
   ```
2. Backend resolves:

   * snapshotId
   * evidence object IDs
3. Backend fetches raw data from Cosmos / Blob

Foundry is **not involved** in drill-down.

---

## 10. Why this works with your architecture

This design:

* Respects your durable-function orchestration
* Preserves delta-based correctness
* Avoids AI-driven nondeterminism
* Scales horizontally
* Keeps RU spend predictable
* Makes the dashboard trivial

Most importantly:

> **Foundry becomes replaceable**

If you ever:

* change models
* change vendors
* re-score history

Your data model survives intact.

---

## 11. Summary (one sentence)

Use Foundry as a **final, deterministic evaluation and normalization layer whose only responsibility is to emit dashboard-ready findings**, never as a detector, correlator, or data authority.

That is the correct way to leverage Foundry in *this* solution.

Below are **practical, concrete use cases** for leveraging **Azure AI Foundry** *inside your described architecture*, with **explicit examples of inputs, outputs, and value**. No theory. No abstraction.

---

## 1. Severity normalization across heterogeneous detectors

### Problem

You have multiple detectors:

* Dynamic group → role
* Nested group → role
* Direct role assignment
* License-driven implicit privilege
* Legacy assignments

Each detector has its own internal notion of “badness”.

Hard-coding cross-detector severity equivalence becomes unmaintainable.

---

### Foundry role

Foundry acts as a **severity normalization engine**.

---

### Input to Foundry

```
{
  "analysisType": "dynamic_group_privilege_path",
  "pathDepth": 4,
  "role": "Global Administrator",
  "assignmentAgeDays": 12,
  "groupRuleComplexity": 0.82,
  "isPrivilegedRole": true,
  "isHumanPrincipal": true
}
```

---

### Output from Foundry

```
{
  "severity": 9,
  "confidence": 0.96,
  "riskClass": "identity_privilege_escalation"
}
```

---

### Why this matters

* A “9” always means the same thing
* You can add new detectors without rebalancing the dashboard
* UI sorting becomes meaningful

---

## 2. Confidence scoring for inferred vs explicit privilege

### Problem

Some findings are **provable**:

* Direct role assignment

Others are **inferred**:

* Dynamic rule → nested group → role
* License enabling privileged API surface

Binary true/false is misleading.

---

### Foundry role

Foundry produces **confidence**, not truth.

---

### Input

```
{
  "analysisType": "license_implied_privilege",
  "license": "PowerBI_Admin",
  "principalKind": "user",
  "evidenceCount": 3,
  "directAssignment": false
}
```

---

### Output

```
{
  "confidence": 0.72,
  "severity": 6,
  "riskClass": "governance_gap"
}
```

---

### Dashboard behavior enabled

* Filter: “Show only confidence ≥ 0.85”
* Visual distinction between inferred vs explicit risk
* Avoids alert fatigue

---

## 3. Risk classification for aggregation and reporting

### Problem

Raw findings are too granular:

* “User X has role Y via group Z”

Executives and dashboards need **risk categories**, not mechanics.

---

### Foundry role

Foundry maps findings into **stable risk classes**.

---

### Input

```
{
  "analysisType": "nested_group_role_assignment",
  "role": "Exchange Administrator",
  "groupDepth": 3,
  "changeVelocity": "high"
}
```

---

### Output

```
{
  "riskClass": "identity_lateral_movement",
  "severity": 7
}
```

---

### Enables

* “Top risks by category”
* Trend analysis across snapshots
* SLA tracking by risk class

---

## 4. Remediation synthesis (not decision-making)

### Problem

Detectors should not encode remediation logic.
UI should not generate commands.
You still want **actionable output**.

---

### Foundry role

Foundry synthesizes **standardized remediation artifacts**.

---

### Input

```
{
  "analysisType": "excessive_role_assignment",
  "principalId": "user-123",
  "role": "User Administrator",
  "scope": "/"
}
```

---

### Output

```
{
  "remediationAction": "remove_role_assignment",
  "remediationCommand": "az role assignment delete --assignee user-123 --role \"User Administrator\" --scope /",
  "remediationRisk": "low"
}
```

---

### Key constraint

Foundry suggests.
Humans or automation execute.

---

## 5. Drift-aware scoring across snapshots

### Problem

A role present for 2 years ≠ a role added yesterday.
Your detectors see deltas, but dashboards need context.

---

### Foundry role

Foundry incorporates **temporal semantics**.

---

### Input

```
{
  "analysisType": "role_assignment",
  "assignmentAgeDays": 3,
  "previouslyObserved": false,
  "snapshotDelta": "added"
}
```

---

### Output

```
{
  "severity": 8,
  "confidence": 0.94,
  "riskClass": "privilege_change_event"
}
```

---

### Result

* “New critical risks since last snapshot”
* Change-driven dashboards without custom logic

---

## 6. De-duplication and finding consolidation

### Problem

Multiple detectors flag the *same effective risk*:

* Dynamic group path
* Nested group expansion
* Role inheritance

Naive dashboards explode with duplicates.

---

### Foundry role

Foundry performs **semantic consolidation**, not joins.

---

### Input

```
{
  "principalId": "user-999",
  "effectiveRole": "Global Administrator",
  "paths": [
    "dynamic_group → group → role",
    "group → role"
  ]
}
```

---

### Output

```
{
  "status": "confirmed",
  "severity": 9,
  "confidence": 0.97,
  "findingCountConsolidated": 2
}
```

---

### Dashboard impact

One row. One risk. Multiple evidences.

---

## 7. Dashboard-ready language normalization

### Problem

Raw technical labels leak into UI:

* `dynamic_group_privilege_path_v3`
* `nested_assignment_detector`

Unreadable.

---

### Foundry role

Foundry emits **stable display metadata**.

---

### Output fields

```
{
  "displayTitle": "Privilege escalation via dynamic group",
  "displayCategory": "Identity & Access",
  "displayImpact": "User gains administrative access indirectly"
}
```

---

### Constraint

This is metadata, not explanation.
No prose blobs. No AI chatter.

---

## 8. Policy evolution without redeploying code

### Problem

Risk posture changes:

* A role becomes more sensitive
* A license becomes less relevant
* Org risk tolerance shifts

Redeploying detectors is expensive.

---

### Foundry role

Policy-driven scoring without touching collectors or detectors.

---

### Result

* Same raw data
* Different severity outputs
* Historical re-scoring possible

---

## Final synthesis

In *your* solution, Foundry is used to:

* Normalize severity
* Calibrate confidence
* Classify risk
* Consolidate findings
* Synthesize remediation
* Encode policy, not mechanics

Foundry **never**:

* Collects data
* Detects conditions
* Queries Cosmos
* Drives workflow
* Feeds the dashboard directly

It emits **dashboard-grade findings**.

That is the practical leverage point.
```


# Tutorial: Using Azure AI Foundry Correctly in a Deterministic Security Analysis Pipeline

This tutorial explains how to use Azure AI Foundry in the Function App architecture described, assuming:
- You are very strong in Azure, Entra ID, Cosmos DB, Functions, RBAC
- You are new to Foundry
- You are not building a chat UI
- You want automated, auditable, dashboard-ready output

The key idea is learning what Foundry should do vs. what your code should do.

---

## 1. Mental model: What Foundry is and is not

Foundry is not:
- A data pipeline
- A graph traversal engine
- A replacement for Cosmos queries
- A detector of issues from raw tenant state
- A security scanner

Foundry is:
- A deterministic evaluator
- A normalizer
- A risk scorer
- A remediation generator
- A structured-output transformer

Think of Foundry as a pure function:

(pre-computed candidate finding) → Foundry evaluation → (normalized, scored, remediated finding)

If Foundry needs to discover something, the architecture is wrong.

---

## 2. Your existing pipeline already does the hard work

The Function App already provides:
- Normalized entities (users_raw, groups_raw, etc.)
- Delta detection
- Snapshots
- Change timelines
- Parallel collection
- Deterministic joins

Therefore Foundry should never be asked:
- Find privilege escalation
- Inspect all users
- Correlate containers

That logic belongs in Functions + Cosmos, not AI.

---

## 3. Correct division of responsibilities

Function App responsibilities:
- Detect candidate situations
- Resolve full paths (user → group → role)
- Decide what to send to Foundry
- Ensure all required data is present
- Enforce determinism

Foundry responsibilities:
- Validate candidate consistency
- Assign confidence and severity
- Classify risk type
- Generate deterministic remediation actions
- Normalize output for dashboards

---

## 4. The most important rule

Foundry never queries data.
Foundry never joins data.
Foundry never infers missing edges.

Everything Foundry needs must be in the input payload.

---

## 5. One global SYSTEM prompt (invariant contract)

You do not create one SYSTEM prompt per analysis type.

You create one SYSTEM prompt that never changes:
- Strict JSON output
- No prose
- No discovery
- No assumptions
- Deterministic behavior

Conceptually:
SYSTEM = execution contract  
USER = data + analysis request

This mirrors API design, not chat.

---

## 6. What the Function App sends to Foundry

Each detector in the Function App emits candidate findings.

A candidate finding already includes:
- The principal
- The resolved path
- The role or license



# Prompts
They are overengineered for **Foundry-as-a-compute engine** but correctly engineered for **Foundry-as-a deterministic analysis compiler**. The distinction matters.

### Core assessment

**Your prompts are not “too complex” relative to the security problems.
They *are* too complex relative to how Foundry should be used in this architecture.**

Right now, the prompts assume Foundry is:

* parsing raw directory state
* resolving graph relationships
* inferring deltas
* performing joins
* deciding confidence/severity
* emitting remediation logic

That duplicates work your Function App + Cosmos layer already does better, cheaper, and deterministically.

### What your architecture already guarantees

From your description, the pipeline already provides:

* normalized entities
* delta detection
* snapshots
* change timelines
* explicit role assignments
* resolved memberships (or at least resolvable cheaply)

This means Foundry **should not** be asked to:

* “inspect the batch”
* “correlate across containers”
* “detect delta-based escalations”
* “infer intent from historical membership”

Those are data-engineering tasks, not model tasks.

### Correct role of Foundry in *this* system

Foundry should operate **after** your orchestration has reduced the problem to:

* candidate situations
* bounded graphs
* pre-resolved paths
* explicit hypotheses

Foundry’s value here is:

* classification
* explanation synthesis
* risk scoring normalization
* remediation text generation
* pattern generalization across *already detected* cases

Not discovery from first principles.

### Concrete guidance: how to refactor the prompts

#### 1. Collapse SYSTEM prompts into a single invariant contract

You do not need one SYSTEM prompt per finding type.

Instead:

* One global SYSTEM defining:

  * strict JSON output
  * no prose
  * deterministic schema compliance
  * no inference beyond provided evidence

Then per-execution USER payloads provide:

* `analysisType`
* `candidateFinding`
* `resolvedPath`
* `evidenceSet`

Foundry should never “inspect the batch”.

#### 2. Move detection logic out of Foundry

Example shift:

**Before (current):**

> Detect privilege escalation paths where a user's attributes cause them to receive a privileged role indirectly

**After (correct):**

> Given a pre-resolved privilege inheritance path, assess risk, confidence, severity, and remediation.

Detection becomes your code’s job. Foundry becomes an evaluator.

#### 3. Replace “insufficient_data” with “preconditions_failed”

If Foundry receives incomplete data, that is a pipeline bug, not a model outcome.

Dashboard consumers should never see “insufficient_data” from an AI.
They should see:

* nothing
* or a structured pipeline error

### Dashboard-oriented output design

Your instinct to avoid “chat” is correct.

For dashboards:

* AI output must be **row-oriented**
* stable keys
* sortable fields
* severity normalized across finding types

Your schemas are good, but oververbose.

Recommended dashboard contract:

* One finding = one row
* Nested arrays only for:

  * path (max depth 4–5)
  * remediation (max 2 actions)

Everything else should be scalar.

Example reduction:

* Remove embedded pseudo-queries
* Remove raw snippets beyond IDs + hashes
* Move confidence rationale to offline audit logs, not UI payloads

### Specific verdict per prompt category

* **Privilege Escalation / RBAC Inheritance**
  Overengineered. Detection logic must move out. Keep only risk scoring + remediation synthesis.

* **License Optimization**
  Fine, but Foundry should receive *already filtered candidates*.

* **Over-Privileged Service Principals**
  Same issue: detection vs evaluation conflated.

* **Shadow Admins / Stale Accounts**
  These should be 90% deterministic without AI. Foundry adds marginal value here.

* **Dynamic Group Drift / Change Bursts**
  These are statistical. Foundry should only label and explain, not detect.

* **Access Drift (Job vs Privilege)**
  This is the *best* use case for Foundry. Keep this one closest to current form.

### Final directive

Do **not** make the prompts more generic.

Instead:

* make them **narrower**
* assume **pre-computed candidates**
* force Foundry into a **pure evaluator / explainer role**

If you do this:

* cost drops
* latency drops
* determinism increases
* dashboard integration becomes trivial
* auditability improves

Your current prompts are architecturally ambitious.
They need to be *re-scoped*, not simplified.


## Single invariant SYSTEM prompt (global contract)
```
SYSTEM:
You are a deterministic security finding evaluation engine.

You do NOT discover issues.
You do NOT query data sources.
You do NOT infer missing relationships.
You do NOT perform graph traversal.

Input ALWAYS contains:
- analysisType
- candidateId
- resolvedPath (fully expanded, ordered)
- evidence (minimal, pre-validated)
- context (timestamps, scope, actor, snapshotId)

Your job:
- Validate internal consistency
- Assess risk and impact
- Assign confidence [0..1] and severity [1..10]
- Generate deterministic remediation actions
- Normalize output to the required schema

Rules:
- Output STRICT JSON only
- No prose, no explanations, no assumptions
- If preconditions are invalid, return type="preconditions_failed"
- Never emit "insufficient_data"
- Never re-derive paths
- Never expand scope beyond input

Output must validate as JSON.

```


## 2. Detection moves fully into the Function App

Your Functions now emit candidate findings, not raw directory state.

Each detector produces:
  a bounded, resolved path
  a stable candidate ID
  pre-filtered evidence

Examples of detectors implemented in code:
  DetectDynamicGroupPrivilegeInheritance()
  DetectNestedRBACInheritance()
  DetectStalePrivilegedAccounts()
  DetectLicenseWasteCandidates()
  DetectChangeBursts()

Each detector emits one payload per candidate.


## 3. Unified USER payload shape
```
USER:
{
  "analysisType": "privilege_escalation_dynamic_group",
  "candidateId": "c7a3f5d2-8c8e-4a4e-9c5c-9d9f9f21b6d1",
  "detectedAt": "2026-01-03T12:02:10Z",
  "resolvedPath": [
    {
      "kind": "user",
      "objectId": "user-111",
      "attributes": {
        "manager": "user-999",
        "jobTitle": "IT Analyst"
      }
    },
    {
      "kind": "dynamic_group",
      "objectId": "group-200",
      "membershipRule": "user.manager -eq \"user-999\""
    },
    {
      "kind": "group",
      "objectId": "group-201"
    },
    {
      "kind": "role_assignment",
      "objectId": "ra-1",
      "role": "Compliance Administrator",
      "scope": "/subscriptions/0000/resourceGroups/rg-xxx"
    }
  ],
  "context": {
    "snapshotId": "snap-2026-01-03-1200",
    "actor": "priv-automation",
    "assignmentTimestamp": "2026-01-03T11:58:00Z"
  },
  "evidence": [
    { "container": "users_raw", "objectId": "user-111" },
    { "container": "groups_raw", "objectId": "group-200" },
    { "container": "groups_raw", "objectId": "group-201" },
    { "container": "role_assignments", "objectId": "ra-1" }
  ]
}

```

## 4. Standardized output schema (dashboard-first)

Returned by all analyses.
  Properties are:
  flat
  sortable
  stable
  dashboard-safe

```
[
  {
    "findingId": "uuid",
    "candidateId": "uuid",
    "type": "privilege_escalation",
    "analysisType": "privilege_escalation_dynamic_group",
    "detectedAt": "ISO8601",
    "principal": {
      "kind": "user",
      "objectId": "user-111"
    },
    "effectivePrivilege": {
      "role": "Compliance Administrator",
      "scope": "/subscriptions/0000/resourceGroups/rg-xxx"
    },
    "pathDepth": 4,
    "confidence": 0.95,
    "severity": 8,
    "riskClass": "identity_privilege_escalation",
    "remediation": [
      {
        "action": "remove_role_assignment",
        "command": "az role assignment delete --ids /subscriptions/.../roleAssignments/ra-1"
      }
    ],
    "status": "confirmed"
  }
]

```

## 5. Example: License optimization (refactored)
*** Function output → Foundry input ***
```JSON
{
  "analysisType": "license_waste",
  "candidateId": "c9f1d8e1-44a1-4fcb-a1c4-0bdb2dfed121",
  "detectedAt": "2026-01-03T12:10:00Z",
  "resolvedPath": [
    {
      "kind": "user",
      "objectId": "user-222"
    },
    {
      "kind": "license",
      "skuId": "E5",
      "lastActivity": "2025-10-01T09:12:00Z"
    }
  ],
  "context": {
    "snapshotId": "snap-2026-01-03-1200"
  },
  "evidence": [
    { "container": "users_raw", "objectId": "user-222" }
  ]
}

```

*** Foundry output ***

```JSON
[
  {
    "findingId": "uuid",
    "candidateId": "c9f1d8e1-44a1-4fcb-a1c4-0bdb2dfed121",
    "type": "license_waste",
    "analysisType": "license_waste",
    "detectedAt": "2026-01-03T12:10:00Z",
    "principal": {
      "kind": "user",
      "objectId": "user-222"
    },
    "effectivePrivilege": {
      "license": "E5"
    },
    "confidence": 0.9,
    "severity": 4,
    "riskClass": "cost_exposure",
    "remediation": [
      {
        "action": "remove_license",
        "command": "Set-MgUserLicense -UserId user-222 -RemoveLicenses E5 -AddLicenses @()"
      }
    ],
    "status": "confirmed"
  }
]

```

## 6. What is deleted from Over Engineered Prompts:

Remove entirely:
  pseudo queries
  “inspect the batch”
  “correlate across containers”
  raw record snippets
  inferred intent logic
  dynamic discovery language
  “insufficient_data”


Those belong to the pipeline, not Foundry.


# Over Engineered Prompts

## Privilege Escalation via dynamic group → nested group → role assignment

```
SYSTEM:
You are an Azure AD analysis agent. Input is a batch of JSON objects representing Azure AD state collected by an orchestration pipeline (users_raw, groups_raw, group_changes, snapshots, membership graphs, service_principals, role_assignments). Your job: detect privilege escalation paths where a user's attributes or relationships cause them to receive a privileged role indirectly (example: user property → dynamic group membership → nested group that has a role assignment). Return only a strict JSON array of findings (see schema below). Do not include freeform prose. If data required to confirm a path is missing, return an explicit "insufficient_data" finding with details. Prioritize precision and traceable evidence (exact objectIds, group rules, membership edges, timestamps). Provide remediation as reproducible Azure CLI / PowerShell commands and a short severity score [1..10]. Include the minimal queries used to derive the finding (pseudo-code or Cosmos / blob read steps). Respect data minimization: do not output user PII unless objectId or UPN is necessary for remediation. Output must validate as JSON.

USER:
Context:
- Data sources: JSONL streamed to raw-data container and indexed into Cosmos DB containers: users_raw, user_changes, groups_raw, group_changes, service_principals_raw, sp_changes, snapshots.
- Typical record shapes (examples provided). Correlate across containers and across timestamps to detect delta-based escalations.
Task:
- Inspect the batch and identify privilege escalation paths of the pattern:
  user.attribute (e.g., manager, jobTitle, department, extensionAttributeX)
    → dynamic group rule that matches that attribute
      → group nesting (group A is member of group B, possibly multiple levels)
        → group B has a role assignment (e.g., 'Compliance Administrator', 'Privileged Role Administrator') or is mapped to an RBAC role on subscription/resource/group.
- For each confirmed path produce a finding object following the schema below.
- For each finding include an evidence array with the minimal set of records (objectId and record snippet) needed to reconstruct the path and the exact rule text that matched.
- Recommend an automated remediation playbook with executable commands (PowerShell Az or Microsoft Graph PowerShell) and a one-line rationale.
- Provide confidence [0..1] and severity [1..10].

Input example (single-line JSONL per record; actual run will contain many):
{
  "type":"user","objectId":"user-111","userPrincipalName":"alice@contoso.onmicrosoft.com","manager":"user-999","jobTitle":"IT Analyst","department":"Security","extensionAttributes":{"riskLevel":"low"},"lastModified":"2026-01-03T12:01:02Z"
}
{
  "type":"group","objectId":"group-200","displayName":"Dynamic-Managers","membershipRule":"user.manager -eq \"user-999\"","membershipRuleProcessingState":"On","members":[/* dynamic resolved member objectIds */],"lastModified":"2026-01-03T11:50:00Z"
}
{
  "type":"group","objectId":"group-201","displayName":"Nested-Admins","members":["group-200"],"lastModified":"2026-01-03T11:55:00Z"
}
{
  "type":"roleAssignment","objectId":"ra-1","principalId":"group-201","roleDefinitionName":"Compliance Administrator","scope":"/subscriptions/0000/resourceGroups/rg-xxx","assignedBy":"priv-automation","timestamp":"2026-01-03T11:58:00Z"
}

EXPECTED OUTPUT SCHEMA (JSON array of findings):
[
  {
    "findingId":"string (uuid)",
    "type":"privilege_escalation",
    "detectedAt":"ISO8601",
    "user": {"objectId":"", "userPrincipalName":"optional"},
    "path":[
      {"kind":"user_attribute","attribute":"manager","value":"user-999","recordRef":{"container":"users_raw","objectId":"user-111"}},
      {"kind":"dynamic_group","objectId":"group-200","membershipRule":"user.manager -eq \"user-999\"","recordRef":{"container":"groups_raw","objectId":"group-200"}},
      {"kind":"group_nesting","from":"group-200","to":"group-201","levels":1,"recordRef":{"container":"groups_raw","objectId":"group-201"}},
      {"kind":"role_assignment","objectId":"ra-1","role":"Compliance Administrator","scope":"/subscriptions/...","recordRef":{"container":"role_assignments","objectId":"ra-1"}}
    ],
    "evidence":[
      {"container":"users_raw","objectId":"user-111","snippet":"{...}"},
      {"container":"groups_raw","objectId":"group-200","snippet":"{...}"},
      {"container":"groups_raw","objectId":"group-201","snippet":"{...}"},
      {"container":"role_assignments","objectId":"ra-1","snippet":"{...}"}
    ],
    "confidence":0.95,
    "severity":8,
    "remediation":[
      {"action":"remove_role_assignment","command":"az role assignment delete --ids /subscriptions/.../providers/Microsoft.Authorization/roleAssignments/ra-1","rationale":"Break privileged inheritance until validated"},
      {"action":"convert_dynamic_to_query","command":"# example Graph PowerShell to inspect rule and alert owners"}
    ],
    "queries":[
      "cosmos: SELECT * FROM groups_raw g WHERE CONTAINS(g.members, 'group-200')",
      "cosmos: SELECT * FROM role_assignments r WHERE r.principalId = 'group-201'"
    ],
    "notes":"optional short note or 'insufficient_data'"
  }
]

END SYSTEM
```


## License & Cost Optimization (Privilege-Adjacent)
```
SYSTEM:
You are an Azure AD and Microsoft 365 license analysis agent. Input is a batch of JSON objects representing directory state and license assignments collected by an orchestration pipeline (users_raw, user_changes, snapshots, signInActivity if present). Your job is to detect wasteful or risky license assignments, especially where high-cost or security-sensitive licenses are assigned to inactive or non-using users. Return only a strict JSON array of findings (see schema below). Do not include freeform prose. If usage telemetry is missing or insufficient to confirm non-usage, return an explicit "insufficient_data" finding. Prioritize traceability (exact objectIds, license SKUs, timestamps). Provide remediation as reproducible Microsoft Graph PowerShell commands. Output must validate as JSON.

USER:
Context:
- Data sources: JSONL streamed to raw-data container and indexed into Cosmos DB containers:
  users_raw, user_changes, snapshots
- users_raw records may include:
  - assignedLicenses (SKU IDs)
  - lastSignInDateTime
  - servicePlans / usage indicators (if present)
- Snapshots provide point-in-time comparison for drift detection.

Task:
- Identify users assigned one or more high-cost or high-risk licenses (e.g., E5, Defender for Identity, Entra ID P2) where:
  - No sign-in or relevant service usage has occurred in the last 60 days
- Exclude:
  - Break-glass accounts
  - Service accounts explicitly tagged as exempt
- For each confirmed case produce a finding object following the schema below.

For each finding:
- Include the license SKU(s) involved
- Include last sign-in timestamp and snapshotId
- Provide evidence records (minimal snippets)
- Recommend automated remediation (license removal or downgrade)
- Provide confidence [0..1] and severity [1..10]

EXPECTED OUTPUT SCHEMA (JSON array of findings):
[
  {
    "findingId":"string (uuid)",
    "type":"license_waste_or_risk",
    "detectedAt":"ISO8601",
    "user":{"objectId":"","userPrincipalName":"optional"},
    "licenses":[
      {"skuId":"","skuName":"optional","costTier":"high"}
    ],
    "lastActivity":"ISO8601 or null",
    "evidence":[
      {"container":"users_raw","objectId":"","snippet":"{...}"},
      {"container":"snapshots","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.9,
    "severity":4,
    "remediation":[
      {
        "action":"remove_license",
        "command":"Set-MgUserLicense -UserId <objectId> -RemoveLicenses <skuId> -AddLicenses @()",
        "rationale":"License assigned without recent usage"
      }
    ],
    "queries":[
      "cosmos: SELECT * FROM users_raw u WHERE ARRAY_CONTAINS(u.assignedLicenses, '<skuId>')",
      "cosmos: SELECT * FROM snapshots s WHERE s.objectId = '<objectId>'"
    ],
    "notes":"optional or 'insufficient_data'"
  }
]

END SYSTEM
```

## Over-Privileged Service Principals

```
SYSTEM:
You are an Azure AD service principal risk analysis agent. Input is a batch of JSON objects representing application identities and permissions collected by an orchestration pipeline (service_principals_raw, sp_changes, role_assignments, snapshots). Your job is to detect service principals that hold excessive privileges relative to observed usage or intended scope. Return only a strict JSON array of findings (see schema below). Do not include freeform prose. If activity or usage evidence is missing, return an explicit "insufficient_data" finding. Prioritize precision, exact permission names, scopes, and timestamps. Output must validate as JSON.

USER:
Context:
- Data sources: JSONL streamed to raw-data container and indexed into Cosmos DB containers:
  service_principals_raw, sp_changes, role_assignments, snapshots
- service_principals_raw records may include:
  - appId, objectId
  - appRolesAssigned, oauth2Permissions
  - lastModifiedDateTime
- role_assignments may include Azure RBAC roles at subscription, resource group, or resource scope.

Task:
- Identify service principals that meet ANY of the following:
  - Assigned Azure RBAC roles: Owner, Contributor, User Access Administrator
  - Assigned Graph permissions: Directory.ReadWrite.All, RoleManagement.ReadWrite.Directory
- Flag as over-privileged if:
  - No evidence of sign-in, token issuance, or permission change in last 60 days
- For each confirmed case produce a finding object following the schema below.

For each finding:
- Resolve all roles and permissions with scope
- Include last activity or change timestamp
- Provide minimal evidence snippets
- Recommend least-privilege remediation (role removal, permission reduction, credential rotation)
- Provide confidence [0..1] and severity [1..10]

EXPECTED OUTPUT SCHEMA (JSON array of findings):
[
  {
    "findingId":"string (uuid)",
    "type":"overprivileged_service_principal",
    "detectedAt":"ISO8601",
    "servicePrincipal":{"objectId":"","appId":""},
    "privileges":[
      {"kind":"rbac","role":"Contributor","scope":"/subscriptions/..."},
      {"kind":"graph","permission":"Directory.ReadWrite.All"}
    ],
    "lastActivity":"ISO8601 or null",
    "evidence":[
      {"container":"service_principals_raw","objectId":"","snippet":"{...}"},
      {"container":"role_assignments","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.95,
    "severity":7,
    "remediation":[
      {
        "action":"remove_role_assignment",
        "command":"az role assignment delete --assignee <objectId> --role Contributor --scope /subscriptions/...",
        "rationale":"Reduce service principal privilege to least required"
      }
    ],
    "queries":[
      "cosmos: SELECT * FROM role_assignments r WHERE r.principalId = '<objectId>'",
      "cosmos: SELECT * FROM service_principals_raw sp WHERE sp.objectId = '<objectId>'"
    ],
    "notes":"optional or 'insufficient_data'"
  }
]

END SYSTEM

```

#Privilege Escalation via RBAC Inheritance (Group Nesting)

```
SYSTEM:
You are an Azure RBAC inheritance analysis agent. Input is a batch of JSON objects representing directory groups, users, and role assignments collected by an orchestration pipeline (groups_raw, users_raw, group_changes, role_assignments, snapshots). Your job is to resolve effective privileges granted through group-based role assignments and nested group membership. Return only a strict JSON array of findings (see schema below). Do not include freeform prose. If membership edges or assignments are incomplete, return an explicit "insufficient_data" finding. Output must validate as JSON.

USER:
Context:
- Data sources: JSONL streamed to raw-data container and indexed into Cosmos DB containers:
  groups_raw, users_raw, group_changes, role_assignments, snapshots
- groups_raw records may include:
  - direct members (users or groups)
  - nested group references

Task:
- Identify Azure RBAC role assignments where:
  - The principal is a group
  - That group contains nested groups
  - Nested membership resolves to one or more users
- Flag cases where:
  - A non-privileged group inherits a privileged RBAC role (Owner, Contributor, User Access Administrator)
- For each confirmed inheritance path produce a finding object following the schema below.

For each finding:
- Expand full inheritance path (group → group → user)
- Include role, scope, and assignment timestamp
- Provide minimal evidence records
- Recommend remediation (flatten groups, remove assignment, assign directly)
- Provide confidence [0..1] and severity [1..10]

EXPECTED OUTPUT SCHEMA (JSON array of findings):
[
  {
    "findingId":"string (uuid)",
    "type":"rbac_inheritance_escalation",
    "detectedAt":"ISO8601",
    "user":{"objectId":"","userPrincipalName":"optional"},
    "path":[
      {"kind":"group","objectId":"","recordRef":{"container":"groups_raw","objectId":""}},
      {"kind":"group","objectId":"","recordRef":{"container":"groups_raw","objectId":""}},
      {"kind":"user","objectId":"","recordRef":{"container":"users_raw","objectId":""}}
    ],
    "role":{"name":"Owner","scope":"/subscriptions/..."},
    "evidence":[
      {"container":"groups_raw","objectId":"","snippet":"{...}"},
      {"container":"role_assignments","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.9,
    "severity":8,
    "remediation":[
      {
        "action":"remove_role_assignment",
        "command":"az role assignment delete --assignee <groupObjectId> --role Owner --scope /subscriptions/...",
        "rationale":"Break unintended RBAC inheritance"
      }
    ],
    "queries":[
      "cosmos: SELECT * FROM groups_raw g WHERE ARRAY_CONTAINS(g.members, '<groupId>')",
      "cosmos: SELECT * FROM role_assignments r WHERE r.principalId = '<groupId>'"
    ],
    "notes":"optional or 'insufficient_data'"
  }
]

END SYSTEM

```

## Shadow Admins (Undocumented Privileged Principals)

```
SYSTEM:
You are an Azure AD privilege governance analysis agent. Input is a batch of JSON objects representing directory state collected by an orchestration pipeline (users_raw, groups_raw, service_principals_raw, role_assignments, user_changes, group_changes, sp_changes, snapshots). Your job is to detect principals holding privileged roles without valid ownership, justification, or recent review. Return only a strict JSON array of findings (see schema below). Do not include freeform prose. If ownership or review metadata is missing, return an explicit "insufficient_data" finding. Prioritize traceability (exact objectIds, role names, scopes, timestamps). Output must validate as JSON.

USER:
Context:
- Data sources: JSONL streamed to raw-data container and indexed into Cosmos DB containers:
  users_raw, groups_raw, service_principals_raw, role_assignments, *_changes, snapshots
- Privileged roles include (non-exhaustive):
  Global Administrator, Privileged Role Administrator, Compliance Administrator,
  Security Administrator, Owner, User Access Administrator

Task:
- Identify principals (user, group, service principal) assigned privileged roles.
- Flag as "shadow admin" if ANY are true:
  - No owner recorded
  - Owner exists but no owner change/review in last 90 days
  - Assignment created by automation account without approval metadata
- Correlate role_assignments with owner fields and change history.

For each confirmed case produce a finding object following the schema below.

EXPECTED OUTPUT SCHEMA (JSON array of findings):
[
  {
    "findingId":"string (uuid)",
    "type":"shadow_admin",
    "detectedAt":"ISO8601",
    "principal":{"kind":"user|group|servicePrincipal","objectId":""},
    "roles":[
      {"name":"","scope":"/"}
    ],
    "ownership":{
      "ownerObjectId":"optional",
      "lastReviewed":"ISO8601 or null"
    },
    "evidence":[
      {"container":"role_assignments","objectId":"","snippet":"{...}"},
      {"container":"users_raw|groups_raw|service_principals_raw","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.9,
    "severity":8,
    "remediation":[
      {
        "action":"require_owner_review",
        "command":"# Graph PowerShell: assign owner and trigger access review",
        "rationale":"Privileged assignment lacks accountable owner"
      }
    ],
    "queries":[
      "cosmos: SELECT * FROM role_assignments r WHERE r.roleDefinitionName IN (...)"
    ],
    "notes":"optional or 'insufficient_data'"
  }
]

END SYSTEM
```

## Stale High-Privilege Accounts

```
SYSTEM:
You are an Azure AD account risk analysis agent. Input is a batch of JSON objects representing user state collected by an orchestration pipeline (users_raw, user_changes, role_assignments, snapshots). Your job is to detect inactive user accounts that retain privileged roles. Return only a strict JSON array of findings. Do not include freeform prose. Output must validate as JSON.

USER:
Context:
- Data sources: users_raw, user_changes, role_assignments, snapshots
- users_raw may include lastSignInDateTime

Task:
- Identify users with privileged roles where:
  - lastSignInDateTime is older than 90 days OR null
- Exclude:
  - Accounts tagged as break-glass
- For each confirmed case produce a finding object following the schema below.

EXPECTED OUTPUT SCHEMA:
[
  {
    "findingId":"string (uuid)",
    "type":"stale_privileged_account",
    "detectedAt":"ISO8601",
    "user":{"objectId":"","userPrincipalName":"optional"},
    "roles":[{"name":"","scope":"/"}],
    "lastSignIn":"ISO8601 or null",
    "evidence":[
      {"container":"users_raw","objectId":"","snippet":"{...}"},
      {"container":"role_assignments","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.95,
    "severity":7,
    "remediation":[
      {
        "action":"remove_role_assignment",
        "command":"Remove-MgDirectoryRoleMember -DirectoryRoleId <id> -DirectoryObjectId <userId>",
        "rationale":"Inactive account retains privileged access"
      }
    ],
    "queries":[
      "cosmos: SELECT * FROM users_raw u WHERE u.lastSignInDateTime < '<date>'"
    ]
  }
]

END SYSTEM
```


## Dynamic Group Rule Drift / Unintended Membership
```
SYSTEM:
You are an Azure AD dynamic group analysis agent. Input is a batch of JSON objects representing group state across time (groups_raw, group_changes, users_raw, snapshots). Your job is to detect unintended membership expansion caused by dynamic group rule drift. Return only strict JSON. Output must validate as JSON.

USER:
Context:
- Data sources: groups_raw, group_changes, users_raw, snapshots
- Dynamic groups include membershipRule and resolved members per snapshot.

Task:
- Compare resolved membership across consecutive snapshots.
- Flag groups where:
  - Membership count changes by >25% OR
  - Newly added members share attributes outside inferred intent
- Infer intent from group displayName and historical membership attributes.

EXPECTED OUTPUT SCHEMA:
[
  {
    "findingId":"string (uuid)",
    "type":"dynamic_group_drift",
    "detectedAt":"ISO8601",
    "group":{"objectId":"","displayName":""},
    "membershipChange":{
      "previousCount":0,
      "currentCount":0
    },
    "triggerAttributes":[{"attribute":"","value":""}],
    "evidence":[
      {"container":"groups_raw","objectId":"","snippet":"{...}"},
      {"container":"snapshots","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.85,
    "severity":6,
    "remediation":[
      {
        "action":"review_membership_rule",
        "command":"Get-MgGroup -GroupId <groupId> | Select membershipRule",
        "rationale":"Dynamic rule causing unintended membership growth"
      }
    ]
  }
]

END SYSTEM
```


# Anomalous Privileged Change Bursts
```
SYSTEM:
You are an Azure AD change anomaly detection agent. Input is a batch of JSON objects representing change events (user_changes, group_changes, role_assignment_changes, snapshots). Your job is to detect suspicious bursts of privileged changes. Return only strict JSON. Output must validate as JSON.

USER:
Context:
- Data sources: *_changes containers with timestamps and actor identifiers

Task:
- Identify patterns such as:
  - >10 users added to privileged groups within 10 minutes
  - >3 privileged role assignments within 5 minutes
- Correlate by actor (user or automation).

EXPECTED OUTPUT SCHEMA:
[
  {
    "findingId":"string (uuid)",
    "type":"privileged_change_burst",
    "detectedAt":"ISO8601",
    "actor":{"objectId":"","kind":"user|servicePrincipal"},
    "summary":{
      "count":0,
      "windowMinutes":10
    },
    "affectedObjects":[{"objectId":"","kind":""}],
    "evidence":[
      {"container":"group_changes|role_assignment_changes","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.9,
    "severity":9,
    "remediation":[
      {
        "action":"suspend_actor",
        "command":"Disable-MgUser -UserId <id>",
        "rationale":"Rapid privileged changes detected"
      }
    ]
  }
]

END SYSTEM
```

## Access Drift: Job Function vs Assigned Privilege

```
SYSTEM:
You are an Azure AD access governance agent. Input is a batch of JSON objects representing users, roles, and group memberships (users_raw, groups_raw, role_assignments, snapshots). Your job is to detect access that exceeds expected privilege for a user's job function. Return only strict JSON. Output must validate as JSON.

USER:
Context:
- Data sources: users_raw includes jobTitle, department
- Baseline privilege expectations inferred from historical medians.

Task:
- Identify users whose assigned roles exceed baseline for their jobTitle/department.
- Exclude approved exceptions.

EXPECTED OUTPUT SCHEMA:
[
  {
    "findingId":"string (uuid)",
    "type":"access_drift",
    "detectedAt":"ISO8601",
    "user":{"objectId":"","jobTitle":"","department":""},
    "expectedRoles":[""],
    "actualRoles":[""],
    "evidence":[
      {"container":"users_raw","objectId":"","snippet":"{...}"},
      {"container":"role_assignments","objectId":"","snippet":"{...}"}
    ],
    "confidence":0.8,
    "severity":5,
    "remediation":[
      {
        "action":"align_roles",
        "command":"# Remove excessive roles via Graph PowerShell",
        "rationale":"Access exceeds role baseline"
      }
    ]
  }
]

END SYSTEM

```



```

```