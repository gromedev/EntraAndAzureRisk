# V3.1: Graph Features for Attack Path Analysis

> **Status:** Design Document
> **Date:** 2026-01-08
> **Prerequisite:** V3 core implementation complete
> **Reference:** See [PLANNING-Version3.md](PLANNING-Version3.md) for V3 architecture

---

## Executive Summary

V3.1 extends the V3 architecture with three capabilities for Gremlin-based attack path analysis:

1. **Virtual Edges** - Conditional relationships (CA policies, role management policies) represented as graph edges
2. **Synthetic Vertices** - Role definitions as graph vertices (targets that edges point to but don't exist yet)
3. **Gremlin Projection** - Delta-driven projection from Cosmos SQL to Gremlin API

**No container/architecture changes required** - these are purely additive to the existing V3 structure.

**Estimated Cost:** $5-20/month additional
**Value:** Enables BloodHound-style path queries ("Who can reach Global Admin?")

---

## Design Philosophy

### What Gremlin Is

- A **query accelerator** for transitive/path-based questions
- A **runtime graph index** built from relationships we already model
- A **materialized traversal index** over the edges container

### What Gremlin Is NOT

- Not a replacement for `principals`, `resources`, or `edges` containers
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
| **Cosmos SQL** (`principals`, `resources`, `edges`) | Permanent (delta-updated) | ✅ **Primary source** |
| **Changes container** | Permanent (audit trail) | For historical graph replay |

### Query Split Pattern

| Question Type | Store | Example |
|---------------|-------|---------|
| "What is this object?" | SQL / Blob | Get user details |
| "Show raw state at time T" | Blob | Historical audit |
| "Who transitively has access to X?" | **Gremlin** | Path traversal |
| "Why does user have role Y?" | **Gremlin → IDs → SQL** | Resolve path |

**Pattern:** Gremlin returns IDs only. Resolution happens against SQL.

### Minimal Gremlin Data Model

**Vertices:** One per principal/resource
```json
{
  "id": "objectId",
  "label": "principalType",
  "tenantId": "tenantId"
}
```

**Edges:** Subset of relationships (only traversable ones)
```json
{
  "from": "sourceId",
  "to": "targetId",
  "label": "edgeType"
}
```

No displayName, no timestamps, no metadata bloat. Those are resolved from SQL when needed.

### Cost Analysis

| Factor | Impact |
|--------|--------|
| Graph contains IDs + edges only | Orders of magnitude less data |
| No history in Gremlin | No storage bloat |
| No dashboard polling | RUs only burn on explicit requests |
| Serverless mode | Pay only for actual queries |
| Rebuildable from SQL | No migration complexity |

| Scenario | Gremlin Cost | Total System |
|----------|--------------|--------------|
| Dev/Test (occasional queries) | $5-10/month | ~$15-20/month |
| Small Production | $10-20/month | ~$25-35/month |
| Medium Production | $20-50/month | ~$40-70/month |

**Key constraint:** Don't poll Gremlin from dashboards. Static snapshots handle 80% of visualization needs.

---

## Table of Contents

0. [Design Philosophy](#design-philosophy)
1. [Part 1: Virtual Edges](#part-1-virtual-edges)
   - [Conditional Access Policy Edges](#11-conditional-access-policy-edges)
   - [Named Location Edges](#12-named-location-edges)
   - [Role Management Policy Edges](#13-role-management-policy-edges)
   - [Future Virtual Edge Candidates](#14-future-virtual-edge-candidates)
2. [Part 2: Synthetic Vertices](#part-2-synthetic-vertices)
   - [The Problem: Missing Target Vertices](#21-the-problem-missing-target-vertices)
   - [Directory Role Definitions](#22-directory-role-definitions)
   - [Azure Role Definitions](#23-azure-role-definitions)
   - [License SKUs (Optional)](#24-license-skus-optional)
3. [Part 3: Gremlin Projection](#part-3-gremlin-projection)
   - [Architecture Overview](#31-architecture-overview)
   - [Connection Setup](#32-connection-setup)
   - [Vertex Upsert Pattern](#33-vertex-upsert-pattern)
   - [Edge Upsert Pattern](#34-edge-upsert-pattern)
   - [Projection Flow](#35-projection-flow)
   - [RU Cost Optimization](#36-ru-cost-optimization)
   - [TinkerPop 3.6+ Alternative](#37-tinkerpop-36-alternative)
   - [Function App Integration](#38-function-app-integration)
4. [Part 4: Attack Path Queries](#part-4-attack-path-queries)
   - [Gremlin Query Examples](#41-gremlin-query-examples)
   - [Power BI SQL Query Patterns](#42-power-bi-sql-query-patterns)
5. [Implementation Tasks](#implementation-tasks)
6. [Validation Checklist](#validation-checklist)
7. [References](#references)

---

# Part 1: Virtual Edges

## What Are Virtual Edges?

Virtual edges represent **conditional/contextual relationships** that:
- Gate access paths (allow/block/require controls)
- Depend on context (user state, device state, location, risk level)
- Are evaluated at authentication time, not statically defined

Unlike regular edges (groupMember, directoryRole, azureRbac), virtual edges represent **what COULD block** an authentication path, not a direct relationship.

---

## 1.1 Conditional Access Policy Edges

CA policies are the most impactful "gate" - MFA is the #1 security control.

### New Edge Types

| edgeType | Source | Target | Purpose |
|----------|--------|--------|---------|
| `caPolicyTargetsPrincipal` | CA Policy | User/Group | Policy applies to this principal |
| `caPolicyTargetsApplication` | CA Policy | App/SP | Policy protects this app |
| `caPolicyExcludesPrincipal` | CA Policy | User/Group | Principal is excluded (bypass) |
| `caPolicyExcludesApplication` | CA Policy | App/SP | App is excluded (bypass) |

### Edge Schema

```json
{
  "id": "{policyId}_{targetId}_caPolicyTargetsPrincipal",
  "objectId": "{policyId}_{targetId}_caPolicyTargetsPrincipal",
  "edgeType": "caPolicyTargetsPrincipal",
  "sourceId": "{policyId}",
  "sourceType": "conditionalAccessPolicy",
  "sourceDisplayName": "Require MFA for Admins",
  "targetId": "{userId|groupId|All}",
  "targetType": "user|group|allUsers|allGuestUsers|directoryRole",
  "targetDisplayName": "Admin Group",

  "policyState": "enabled|disabled|enabledForReportingButNotEnforced",

  "requiresMfa": true,
  "blocksAccess": false,
  "requiresCompliantDevice": false,
  "requiresHybridAzureADJoin": false,
  "requiresApprovedApp": false,
  "requiresAppProtection": false,

  "clientAppTypes": ["browser", "mobileAppsAndDesktopClients"],
  "hasLocationCondition": true,
  "hasRiskCondition": false,

  "effectiveFrom": "2026-01-08T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

### Binary Flags for Power BI Filtering

| Flag | Description | Source |
|------|-------------|--------|
| `requiresMfa` | Grant control includes MFA | `grantControls.builtInControls -contains 'mfa'` |
| `blocksAccess` | Grant control blocks access entirely | `grantControls.builtInControls -contains 'block'` |
| `requiresCompliantDevice` | Requires Intune-compliant device | `grantControls.builtInControls -contains 'compliantDevice'` |
| `requiresHybridAzureADJoin` | Requires hybrid Azure AD joined device | `grantControls.builtInControls -contains 'domainJoinedDevice'` |
| `requiresApprovedApp` | Requires approved client app | `grantControls.builtInControls -contains 'approvedApplication'` |
| `requiresAppProtection` | Requires app protection policy | `grantControls.builtInControls -contains 'compliantApplication'` |

### Special Cases Handling

| Condition | Edge Handling |
|-----------|---------------|
| `includeUsers: ["All"]` | Create edge with `targetId = "All"`, `targetType = "allUsers"` |
| `includeUsers: ["GuestsOrExternalUsers"]` | Create edge with `targetType = "allGuestUsers"` |
| `includeRoles: [roleTemplateId]` | Create edge with `targetType = "directoryRole"`, `targetId = roleTemplateId` |
| `includeApplications: ["All"]` | Create edge with `targetId = "All"`, `targetType = "allApps"` |
| `includeApplications: ["Office365"]` | Create edge with `targetId = "Office365"`, `targetType = "office365"` |
| `excludeUsers: [userId]` | Create `caPolicyExcludesPrincipal` edge |
| `excludeGroups: [groupId]` | Create `caPolicyExcludesPrincipal` edge with `targetType = "group"` |

### Implementation: Phase 13

Add to `FunctionApp/CollectRelationships/run.ps1`:

```powershell
#region Phase 13: Conditional Access Policy Edges
Write-Verbose "=== Phase 13: Conditional Access Policy Edges ==="

$caPoliciesUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"

while ($caPoliciesUri) {
    $response = Invoke-GraphWithRetry -Uri $caPoliciesUri -AccessToken $graphToken

    foreach ($policy in $response.value) {
        $policyId = $policy.id
        $policyState = $policy.state
        $policyDisplayName = $policy.displayName

        # Extract grant controls
        $grantControls = $policy.grantControls.builtInControls ?? @()
        $requiresMfa = $grantControls -contains 'mfa'
        $blocksAccess = $grantControls -contains 'block'
        $requiresCompliantDevice = $grantControls -contains 'compliantDevice'
        $requiresHybridAzureADJoin = $grantControls -contains 'domainJoinedDevice'
        $requiresApprovedApp = $grantControls -contains 'approvedApplication'
        $requiresAppProtection = $grantControls -contains 'compliantApplication'

        $clientAppTypes = $policy.conditions.clientAppTypes ?? @()
        $hasLocationCondition = ($null -ne $policy.conditions.locations)
        $hasRiskCondition = (($policy.conditions.signInRiskLevels ?? @()).Count -gt 0) -or
                           (($policy.conditions.userRiskLevels ?? @()).Count -gt 0)

        # Common edge properties
        $baseEdge = @{
            sourceId = $policyId
            sourceType = "conditionalAccessPolicy"
            sourceDisplayName = $policyDisplayName
            policyState = $policyState
            requiresMfa = $requiresMfa
            blocksAccess = $blocksAccess
            requiresCompliantDevice = $requiresCompliantDevice
            requiresHybridAzureADJoin = $requiresHybridAzureADJoin
            requiresApprovedApp = $requiresApprovedApp
            requiresAppProtection = $requiresAppProtection
            clientAppTypes = $clientAppTypes
            hasLocationCondition = $hasLocationCondition
            hasRiskCondition = $hasRiskCondition
            effectiveFrom = $timestampFormatted
            effectiveTo = $null
            collectionTimestamp = $timestampFormatted
        }

        #region Process User/Group Inclusions
        $userConditions = $policy.conditions.users

        # Include users
        foreach ($userId in ($userConditions.includeUsers ?? @())) {
            $targetType = switch ($userId) {
                'All' { 'allUsers' }
                'GuestsOrExternalUsers' { 'allGuestUsers' }
                default { 'user' }
            }

            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${userId}_caPolicyTargetsPrincipal"
            $edge.objectId = "${policyId}_${userId}_caPolicyTargetsPrincipal"
            $edge.edgeType = "caPolicyTargetsPrincipal"
            $edge.targetId = $userId
            $edge.targetType = $targetType
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Include groups
        foreach ($groupId in ($userConditions.includeGroups ?? @())) {
            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${groupId}_caPolicyTargetsPrincipal"
            $edge.objectId = "${policyId}_${groupId}_caPolicyTargetsPrincipal"
            $edge.edgeType = "caPolicyTargetsPrincipal"
            $edge.targetId = $groupId
            $edge.targetType = "group"
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Include roles
        foreach ($roleId in ($userConditions.includeRoles ?? @())) {
            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${roleId}_caPolicyTargetsPrincipal"
            $edge.objectId = "${policyId}_${roleId}_caPolicyTargetsPrincipal"
            $edge.edgeType = "caPolicyTargetsPrincipal"
            $edge.targetId = $roleId
            $edge.targetType = "directoryRole"
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Exclude users
        foreach ($userId in ($userConditions.excludeUsers ?? @())) {
            $targetType = if ($userId -eq 'GuestsOrExternalUsers') { 'allGuestUsers' } else { 'user' }

            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${userId}_caPolicyExcludesPrincipal"
            $edge.objectId = "${policyId}_${userId}_caPolicyExcludesPrincipal"
            $edge.edgeType = "caPolicyExcludesPrincipal"
            $edge.targetId = $userId
            $edge.targetType = $targetType
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Exclude groups
        foreach ($groupId in ($userConditions.excludeGroups ?? @())) {
            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${groupId}_caPolicyExcludesPrincipal"
            $edge.objectId = "${policyId}_${groupId}_caPolicyExcludesPrincipal"
            $edge.edgeType = "caPolicyExcludesPrincipal"
            $edge.targetId = $groupId
            $edge.targetType = "group"
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Exclude roles
        foreach ($roleId in ($userConditions.excludeRoles ?? @())) {
            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${roleId}_caPolicyExcludesPrincipal"
            $edge.objectId = "${policyId}_${roleId}_caPolicyExcludesPrincipal"
            $edge.edgeType = "caPolicyExcludesPrincipal"
            $edge.targetId = $roleId
            $edge.targetType = "directoryRole"
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }
        #endregion

        #region Process Application Inclusions/Exclusions
        $appConditions = $policy.conditions.applications

        # Include applications
        foreach ($appId in ($appConditions.includeApplications ?? @())) {
            $targetType = switch ($appId) {
                'All' { 'allApps' }
                'Office365' { 'office365' }
                default { 'application' }
            }

            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${appId}_caPolicyTargetsApplication"
            $edge.objectId = "${policyId}_${appId}_caPolicyTargetsApplication"
            $edge.edgeType = "caPolicyTargetsApplication"
            $edge.targetId = $appId
            $edge.targetType = $targetType
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }

        # Exclude applications
        foreach ($appId in ($appConditions.excludeApplications ?? @())) {
            $targetType = if ($appId -eq 'Office365') { 'office365' } else { 'application' }

            $edge = $baseEdge.Clone()
            $edge.id = "${policyId}_${appId}_caPolicyExcludesApplication"
            $edge.objectId = "${policyId}_${appId}_caPolicyExcludesApplication"
            $edge.edgeType = "caPolicyExcludesApplication"
            $edge.targetId = $appId
            $edge.targetType = $targetType
            $edge.targetDisplayName = ""

            [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
            $stats.CaPolicyEdges++
        }
        #endregion
    }

    $caPoliciesUri = $response.'@odata.nextLink'
}

Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
Write-Verbose "CA policy edges complete: $($stats.CaPolicyEdges)"
#endregion
```

---

## 1.2 Named Location Edges

Named locations are already collected in `policies.jsonl` with `policyType = "namedLocation"`. We create edges linking CA policies to their referenced locations.

### New Edge Type

| edgeType | Source | Target | Purpose |
|----------|--------|--------|---------|
| `caPolicyUsesLocation` | CA Policy | Named Location | Policy references this location condition |

### Edge Schema

```json
{
  "id": "{policyId}_{locationId}_caPolicyUsesLocation",
  "objectId": "{policyId}_{locationId}_caPolicyUsesLocation",
  "edgeType": "caPolicyUsesLocation",
  "sourceId": "{policyId}",
  "sourceType": "conditionalAccessPolicy",
  "sourceDisplayName": "Block access from untrusted locations",
  "targetId": "{locationId}",
  "targetType": "namedLocation",
  "targetDisplayName": "Corporate Network",
  "targetLocationType": "ipNamedLocation|countryNamedLocation",
  "targetIsTrusted": true,
  "locationUsageType": "include|exclude",
  "effectiveFrom": "2026-01-08T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

### Special Cases

| Condition | Edge Handling |
|-----------|---------------|
| `includeLocations: ["All"]` | Create edge with `targetId = "All"`, `targetType = "allLocations"` |
| `includeLocations: ["AllTrusted"]` | Create edge with `targetId = "AllTrusted"`, `targetType = "allTrustedLocations"` |
| `excludeLocations: [locationId]` | Create edge with `locationUsageType = "exclude"` |

### Implementation

Add to Phase 13 after processing users/apps:

```powershell
#region Process Location Conditions
$locationConditions = $policy.conditions.locations

# Include locations
foreach ($locationId in ($locationConditions.includeLocations ?? @())) {
    $targetType = switch ($locationId) {
        'All' { 'allLocations' }
        'AllTrusted' { 'allTrustedLocations' }
        default { 'namedLocation' }
    }

    $edge = $baseEdge.Clone()
    $edge.id = "${policyId}_${locationId}_caPolicyUsesLocation"
    $edge.objectId = "${policyId}_${locationId}_caPolicyUsesLocation"
    $edge.edgeType = "caPolicyUsesLocation"
    $edge.targetId = $locationId
    $edge.targetType = $targetType
    $edge.targetDisplayName = ""
    $edge.locationUsageType = "include"

    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
    $stats.CaPolicyEdges++
}

# Exclude locations
foreach ($locationId in ($locationConditions.excludeLocations ?? @())) {
    $targetType = switch ($locationId) {
        'AllTrusted' { 'allTrustedLocations' }
        default { 'namedLocation' }
    }

    $edge = $baseEdge.Clone()
    $edge.id = "${policyId}_${locationId}_caPolicyUsesLocation_exclude"
    $edge.objectId = "${policyId}_${locationId}_caPolicyUsesLocation_exclude"
    $edge.edgeType = "caPolicyUsesLocation"
    $edge.targetId = $locationId
    $edge.targetType = $targetType
    $edge.targetDisplayName = ""
    $edge.locationUsageType = "exclude"

    [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
    $stats.CaPolicyEdges++
}
#endregion
```

---

## 1.3 Role Management Policy Edges

Role management policies are already collected in `policies.jsonl` with `policyType = "roleManagement"`. These policies define PIM activation requirements (MFA, approval, justification, etc.).

### New Edge Type

| edgeType | Source | Target | Purpose |
|----------|--------|--------|---------|
| `rolePolicyAssignment` | Role Mgmt Policy | Directory Role | Policy applies to this role with activation requirements |

### Edge Schema

```json
{
  "id": "{policyId}_{roleId}_rolePolicyAssignment",
  "objectId": "{policyId}_{roleId}_rolePolicyAssignment",
  "edgeType": "rolePolicyAssignment",
  "sourceId": "{policyId}",
  "sourceType": "roleManagementPolicy",
  "sourceDisplayName": "Global Administrator Policy",
  "targetId": "{roleDefinitionId}",
  "targetType": "directoryRole",
  "targetDisplayName": "Global Administrator",

  "requiresMfaOnActivation": true,
  "requiresApproval": true,
  "requiresJustification": true,
  "requiresTicketInfo": false,
  "maxActivationDurationHours": 8,
  "permanentAssignmentAllowed": false,
  "eligibleAssignmentMaxDurationDays": 365,

  "effectiveFrom": "2026-01-08T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

### Use Cases

- **Attack Path Analysis:** "Which roles can be activated without MFA?" → Find paths where `requiresMfaOnActivation = false`
- **Compliance:** "Which privileged roles don't require approval?" → Query `requiresApproval = false` on privileged role edges
- **Coverage Gap:** "Which roles allow permanent assignment?" → Query `permanentAssignmentAllowed = true`

### Implementation: Phase 14

```powershell
#region Phase 14: Role Management Policy Edges
Write-Verbose "=== Phase 14: Role Management Policy Edges ==="

# Get role management policy assignments
$policyAssignmentsUri = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'"

while ($policyAssignmentsUri) {
    $response = Invoke-GraphWithRetry -Uri $policyAssignmentsUri -AccessToken $graphToken

    foreach ($assignment in $response.value) {
        $policyId = $assignment.policyId
        $roleDefinitionId = $assignment.roleDefinitionId

        # Get the actual policy to extract rules
        $policyUri = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/${policyId}?`$expand=rules"
        $policy = Invoke-GraphWithRetry -Uri $policyUri -AccessToken $graphToken

        # Extract rules from policy
        $requiresMfa = $false
        $requiresApproval = $false
        $requiresJustification = $false
        $requiresTicketInfo = $false
        $maxActivationHours = 8
        $permanentAllowed = $true
        $eligibleMaxDays = 365

        foreach ($rule in $policy.rules) {
            switch ($rule.'@odata.type') {
                '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule' {
                    if ($rule.id -eq 'Enablement_EndUser_Assignment') {
                        $requiresMfa = $rule.enabledRules -contains 'MultiFactorAuthentication'
                        $requiresJustification = $rule.enabledRules -contains 'Justification'
                        $requiresTicketInfo = $rule.enabledRules -contains 'Ticketing'
                    }
                }
                '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule' {
                    if ($rule.id -eq 'Approval_EndUser_Assignment') {
                        $requiresApproval = $rule.setting.isApprovalRequired
                    }
                }
                '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule' {
                    if ($rule.id -eq 'Expiration_EndUser_Assignment') {
                        $maxActivationHours = [int]($rule.maximumDuration -replace 'PT(\d+)H.*', '$1')
                    }
                    elseif ($rule.id -eq 'Expiration_Admin_Eligibility') {
                        $permanentAllowed = -not $rule.isExpirationRequired
                        if ($rule.maximumDuration) {
                            $eligibleMaxDays = [int]($rule.maximumDuration -replace 'P(\d+)D.*', '$1')
                        }
                    }
                }
            }
        }

        $edge = @{
            id = "${policyId}_${roleDefinitionId}_rolePolicyAssignment"
            objectId = "${policyId}_${roleDefinitionId}_rolePolicyAssignment"
            edgeType = "rolePolicyAssignment"
            sourceId = $policyId
            sourceType = "roleManagementPolicy"
            sourceDisplayName = $policy.displayName ?? ""
            targetId = $roleDefinitionId
            targetType = "directoryRole"
            targetDisplayName = ""
            requiresMfaOnActivation = $requiresMfa
            requiresApproval = $requiresApproval
            requiresJustification = $requiresJustification
            requiresTicketInfo = $requiresTicketInfo
            maxActivationDurationHours = $maxActivationHours
            permanentAssignmentAllowed = $permanentAllowed
            eligibleAssignmentMaxDurationDays = $eligibleMaxDays
            effectiveFrom = $timestampFormatted
            effectiveTo = $null
            collectionTimestamp = $timestampFormatted
        }

        [void]$jsonL.AppendLine(($edge | ConvertTo-Json -Compress -Depth 5))
        $stats.RolePolicyEdges++
    }

    $policyAssignmentsUri = $response.'@odata.nextLink'
}

Write-BlobBuffer -Buffer ([ref]$jsonL) @flushParams
Write-Verbose "Role management policy edges complete: $($stats.RolePolicyEdges)"
#endregion
```

---

## 1.4 Future Virtual Edge Candidates

These would require additional API permissions and complexity. Defer to V3.2+.

| Virtual Edge | Gate Type | Data Source | API Required | License |
|--------------|-----------|-------------|--------------|---------|
| `deviceCompliancePassed` | Device → Resource | Intune | deviceManagement/managedDevices | Intune |
| `appProtectionPolicyApplies` | User → App | Intune MAM | deviceAppManagement/managedAppPolicies | Intune |
| `authStrengthRequired` | User → Resource | Auth Strengths | policies/authenticationStrengthPolicies | None |
| `riskGated` | User → Resource | Identity Protection | identityProtection/riskyUsers | P2 |
| `sessionControlled` | User → App | CA Session Controls | Already in CA policies | None |
| `termsOfUseAccepted` | User → App | Terms of Use | identityGovernance/termsOfUse | P1 |

---

# Part 2: Synthetic Vertices

## What Are Synthetic Vertices?

Synthetic vertices are graph nodes for entities that:
- Are **targets of edges** but don't exist as collected entities
- Are needed for Gremlin traversal (`g.V().hasLabel('directoryRole')`)
- Exist in Microsoft APIs but aren't currently collected as resources

---

## 2.1 The Problem: Missing Target Vertices

Currently, several edge types point to targets that **don't exist as vertices**:

| Edge Type | Target Field | Target Vertex Exists? | Impact |
|-----------|--------------|----------------------|--------|
| `directoryRole` | roleDefinitionId | ❌ No vertex | Can't query "who can reach Global Admin" |
| `pimEligible` / `pimActive` | roleDefinitionId | ❌ No vertex | Same |
| `azureRbac` | roleDefinitionId | ❌ No vertex | Can't query "who has Contributor" |
| `license` | skuId | ❌ No vertex | Minor - not attack-path relevant |
| `caPolicyTargets*` (new) | policyId | ❌ No vertex in resources | Policies in separate container |

### Why This Matters for Gremlin

```gremlin
// This query FAILS because there's no "directoryRole" vertex
g.V().hasLabel('directoryRole').has('roleTemplateId', 'global-admin-id')
  .repeat(__.in()).emit().path()

// You'd have to do this awkward edge-based pattern instead:
g.E().hasLabel('directoryRole').has('targetRoleTemplateId', 'global-admin-id')
  .outV().path()
```

---

## 2.2 Directory Role Definitions

### New Collector

**File:** `FunctionApp/CollectDirectoryRoleDefinitions/run.ps1`

**API:** `https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions`

**Output:** `{timestamp}-resources.jsonl` (unified with other resources)

### Schema

```json
{
  "id": "{roleDefinitionId}",
  "objectId": "{roleDefinitionId}",
  "resourceType": "directoryRole",
  "displayName": "Global Administrator",
  "description": "Can manage all aspects of Azure AD and Microsoft services...",
  "roleTemplateId": "62e90394-69f5-4237-9190-012177145e10",
  "isBuiltIn": true,
  "isEnabled": true,
  "isPrivileged": true,
  "rolePermissions": [...],
  "effectiveFrom": "2026-01-08T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

### Privileged Role Detection

```powershell
$privilegedRoleTemplates = @(
    '62e90394-69f5-4237-9190-012177145e10'  # Global Administrator
    'e8611ab8-c189-46e8-94e1-60213ab1f814'  # Privileged Role Administrator
    '194ae4cb-b126-40b2-bd5b-6091b380977d'  # Security Administrator
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'  # Application Administrator
    '158c047a-c907-4556-b7ef-446551a6b5f7'  # Cloud Application Administrator
    '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'  # Privileged Authentication Administrator
    'fe930be7-5e62-47db-91af-98c3a49a38b1'  # User Administrator
    '29232cdf-9323-42fd-ade2-1d097af3e4de'  # Exchange Administrator
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'  # SharePoint Administrator
    '966707d0-3269-4727-9be2-8c3a10f19b9d'  # Password Administrator
)
```

---

## 2.3 Azure Role Definitions

### New Collector

**File:** `FunctionApp/CollectAzureRoleDefinitions/run.ps1`

**API:** `https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01`

**Output:** `{timestamp}-resources.jsonl`

### Schema

```json
{
  "id": "{roleDefinitionId}",
  "objectId": "{roleDefinitionId}",
  "resourceType": "azureRoleDefinition",
  "displayName": "Contributor",
  "description": "Grants full access to manage all resources...",
  "roleName": "Contributor",
  "roleType": "BuiltInRole",
  "isPrivileged": true,
  "permissions": [...],
  "assignableScopes": ["/"],
  "effectiveFrom": "2026-01-08T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

### Privileged Azure Role Detection

```powershell
$privilegedAzureRoles = @(
    'Owner'
    'Contributor'
    'User Access Administrator'
    'Virtual Machine Contributor'
    'Key Vault Administrator'
    'Key Vault Secrets Officer'
    'Storage Account Contributor'
    'Automation Contributor'
)
```

---

## 2.4 License SKUs (Optional)

Not attack-path relevant, but useful for Power BI license reporting.

**API:** `https://graph.microsoft.com/v1.0/subscribedSkus`

**Schema:**

```json
{
  "id": "{skuId}",
  "objectId": "{skuId}",
  "resourceType": "licenseSku",
  "displayName": "Microsoft 365 E5",
  "skuPartNumber": "SPE_E5",
  "skuId": "06ebc4ee-1bb5-47dd-8120-11324bc54e06",
  "consumedUnits": 150,
  "prepaidUnits": { "enabled": 200, "suspended": 0 },
  "effectiveFrom": "2026-01-08T00:00:00Z",
  "collectionTimestamp": "2026-01-08T00:00:00Z"
}
```

---

# Part 3: Gremlin Projection

## 3.1 Architecture Overview

### Why Gremlin Projection?

| Cosmos SQL API | Cosmos Gremlin API |
|----------------|-------------------|
| Document queries (Power BI, reporting) | Graph traversal (attack paths, reachability) |
| `SELECT * FROM edges WHERE edgeType = 'groupMember'` | `g.V('user-id').repeat(out()).until(hasLabel('directoryRole'))` |
| Fast for filtered queries | Fast for path-finding queries |
| No path algorithms built-in | Native path algorithms |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Cosmos DB Account                            │
├─────────────────────────────────────────────────────────────────────┤
│  SQL API Database: EntraData                                        │
│  ├── principals (users, groups, SPs, devices)                       │
│  ├── resources (apps, Azure resources, role definitions)            │
│  ├── edges (all relationships)                                      │
│  ├── policies (CA, role management)                                 │
│  └── changes (delta audit log)                                      │
├─────────────────────────────────────────────────────────────────────┤
│  Gremlin API Database: EntraGraph                                   │
│  └── graph (vertices + edges projected from SQL containers)         │
└─────────────────────────────────────────────────────────────────────┘

Projection Flow:
  changes container (deltas) → ProjectGraphToGremlin → Gremlin vertices/edges
```

---

## 3.2 Connection Setup

### Gremlin.Net in PowerShell Azure Functions

Azure Functions (PowerShell) don't natively include Gremlin.Net. Two options:

**Option A: Include DLL manually**
```powershell
# In run.ps1 or profile.ps1
$gremlinDllPath = Join-Path $PSScriptRoot "lib\Gremlin.Net.dll"
Add-Type -Path $gremlinDllPath
```

**Option B: Use REST API (simpler, slightly less efficient)**
```powershell
# Direct REST calls to Gremlin endpoint
$gremlinEndpoint = "https://$cosmosAccount.gremlin.cosmos.azure.com:443/"
```

### Environment Variables

```powershell
# Required in Function App settings
$env:COSMOS_GREMLIN_ENDPOINT = "wss://your-account.gremlin.cosmos.azure.com:443/"
$env:COSMOS_GREMLIN_DATABASE = "EntraGraph"
$env:COSMOS_GREMLIN_CONTAINER = "graph"
$env:COSMOS_GREMLIN_KEY = "your-primary-key"
```

### Submit-GremlinQuery Helper Function

```powershell
function Submit-GremlinQuery {
    <#
    .SYNOPSIS
        Executes a Gremlin query against Cosmos DB Gremlin API.

    .DESCRIPTION
        Uses Gremlin.Net to submit queries with retry logic.
        Returns query results or throws on failure.

    .PARAMETER Query
        The Gremlin query string to execute.

    .PARAMETER RetryCount
        Number of retries on transient failures (default: 3).
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [int]$RetryCount = 3
    )

    $endpoint = $env:COSMOS_GREMLIN_ENDPOINT
    $database = $env:COSMOS_GREMLIN_DATABASE
    $container = $env:COSMOS_GREMLIN_CONTAINER
    $key = $env:COSMOS_GREMLIN_KEY

    # Create Gremlin client (Gremlin.Net)
    $gremlinServer = [Gremlin.Net.Driver.GremlinServer]::new(
        $endpoint,
        443,
        $true,  # Enable SSL
        "/dbs/$database/colls/$container",
        [Gremlin.Net.Driver.AuthToken]::new("/dbs/$database/colls/$container", $key)
    )

    $connectionPoolSettings = [Gremlin.Net.Driver.ConnectionPoolSettings]::new()
    $connectionPoolSettings.MaxInProcessPerConnection = 32
    $connectionPoolSettings.PoolSize = 4
    $connectionPoolSettings.ReconnectionAttempts = 3
    $connectionPoolSettings.ReconnectionBaseDelay = [TimeSpan]::FromSeconds(1)

    $gremlinClient = [Gremlin.Net.Driver.GremlinClient]::new(
        $gremlinServer,
        [Gremlin.Net.Structure.IO.GraphSON.GraphSON2MessageSerializer]::new(),
        $connectionPoolSettings
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $RetryCount) {
        try {
            $attempt++
            $resultSet = $gremlinClient.SubmitAsync($Query).GetAwaiter().GetResult()

            # Collect results
            $results = @()
            foreach ($result in $resultSet) {
                $results += $result
            }

            return @{
                Success = $true
                Results = $results
                RequestCharge = $resultSet.StatusAttributes["x-ms-request-charge"]
            }
        }
        catch {
            $lastError = $_

            # Check if retryable
            if ($_.Exception.Message -match "429|Request rate is large|TooManyRequests") {
                # Rate limited - back off exponentially
                $backoff = [Math]::Pow(2, $attempt) * 100
                Write-Warning "Rate limited, waiting ${backoff}ms (attempt $attempt of $RetryCount)"
                Start-Sleep -Milliseconds $backoff
            }
            elseif ($_.Exception.Message -match "ServiceUnavailable|Timeout") {
                # Transient failure - retry
                Write-Warning "Transient failure, retrying (attempt $attempt of $RetryCount)"
                Start-Sleep -Milliseconds 500
            }
            else {
                # Non-retryable error
                throw
            }
        }
        finally {
            if ($gremlinClient) {
                $gremlinClient.Dispose()
            }
        }
    }

    throw "Failed after $RetryCount attempts: $lastError"
}
```

---

## 3.3 Vertex Upsert Pattern

### The Problem

If you simply `addV()` every time, you'll create duplicates. We need **idempotent upserts**.

### The Solution: `fold().coalesce()`

```gremlin
g.V('object-id-123')
  .fold()
  .coalesce(
    unfold(),                                    // If found, return existing vertex
    addV('user')                                 // If not found, create new vertex
      .property(id, 'object-id-123')
      .property('tenantId', 'tenant-123')
      .property('displayName', 'John Doe')
      .property('principalType', 'user')
  )
```

**How it works:**
1. `g.V('object-id-123')` - Try to find vertex by ID
2. `.fold()` - Collect results into a list (empty if not found)
3. `.coalesce(unfold(), addV(...))` - If list has items, unfold and return; otherwise, add new vertex

### PowerShell Implementation

```powershell
function Add-GraphVertex {
    <#
    .SYNOPSIS
        Upserts a vertex (principal or resource) to the Gremlin graph.

    .PARAMETER ObjectId
        The unique identifier for the vertex (becomes Gremlin vertex ID).

    .PARAMETER Label
        The vertex label (e.g., 'user', 'group', 'servicePrincipal', 'application').

    .PARAMETER Properties
        Hashtable of additional properties to set on the vertex.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [hashtable]$Properties = @{}
    )

    # Build property string
    $propertyParts = @()
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -ne $value) {
            # Escape single quotes in values
            $escapedValue = $value.ToString().Replace("'", "\'")
            $propertyParts += ".property('$key', '$escapedValue')"
        }
    }
    $propertyString = $propertyParts -join ""

    # Gremlin upsert query
    $query = @"
g.V('$ObjectId')
  .fold()
  .coalesce(
    unfold(),
    addV('$Label')
      .property(id, '$ObjectId')
      $propertyString
  )
"@

    return Submit-GremlinQuery -Query $query
}

# Example usage:
Add-GraphVertex -ObjectId "user-123" -Label "user" -Properties @{
    displayName = "John Doe"
    userPrincipalName = "john@contoso.com"
    principalType = "user"
    tenantId = "tenant-456"
}
```

---

## 3.4 Edge Upsert Pattern

### The Challenge

Edges are trickier because:
1. Both **source** and **target** vertices must exist
2. You need to check if the edge already exists between those specific vertices

### The Solution

```gremlin
g.V('source-id')
  .outE('groupMember')
  .where(inV().hasId('target-id'))
  .fold()
  .coalesce(
    unfold(),                                    // If edge exists, return it
    g.V('source-id')                             // Otherwise, create new edge
      .addE('groupMember')
      .to(g.V('target-id'))
      .property('effectiveFrom', '2026-01-08')
  )
```

**How it works:**
1. `g.V('source-id')` - Start at source vertex
2. `.outE('groupMember')` - Find outgoing edges of this type
3. `.where(inV().hasId('target-id'))` - Filter to edges pointing to target
4. `.fold().coalesce(unfold(), addE(...))` - Return existing or create new

### PowerShell Implementation

```powershell
function Add-GraphEdge {
    <#
    .SYNOPSIS
        Upserts an edge (relationship) between two vertices in the Gremlin graph.

    .PARAMETER SourceId
        The ID of the source vertex.

    .PARAMETER TargetId
        The ID of the target vertex.

    .PARAMETER EdgeType
        The edge label (e.g., 'groupMember', 'directoryRole', 'azureRbac').

    .PARAMETER Properties
        Hashtable of additional properties to set on the edge.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceId,

        [Parameter(Mandatory = $true)]
        [string]$TargetId,

        [Parameter(Mandatory = $true)]
        [string]$EdgeType,

        [hashtable]$Properties = @{}
    )

    # Build property string
    $propertyParts = @()
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -ne $value) {
            $escapedValue = $value.ToString().Replace("'", "\'")
            $propertyParts += ".property('$key', '$escapedValue')"
        }
    }
    $propertyString = $propertyParts -join ""

    # Gremlin edge upsert query
    $query = @"
g.V('$SourceId')
  .outE('$EdgeType')
  .where(inV().hasId('$TargetId'))
  .fold()
  .coalesce(
    unfold(),
    g.V('$SourceId')
      .addE('$EdgeType')
      .to(g.V('$TargetId'))
      $propertyString
  )
"@

    return Submit-GremlinQuery -Query $query
}

# Example usage:
Add-GraphEdge -SourceId "user-123" -TargetId "group-456" -EdgeType "groupMember" -Properties @{
    effectiveFrom = "2026-01-08T00:00:00Z"
    sourceType = "user"
    targetType = "group"
}
```

---

## 3.5 Projection Flow

### Delta-Driven Projection

Instead of projecting all data every run, we project only **changes** from the delta audit log:

```powershell
function Invoke-GraphProjection {
    <#
    .SYNOPSIS
        Projects delta changes from Cosmos SQL to Gremlin API.

    .DESCRIPTION
        Reads the 'changes' container for recent deltas and projects
        new/updated entities to Gremlin. Handles soft deletes.
    #>
    param (
        [DateTime]$Since = (Get-Date).AddHours(-1)
    )

    $stats = @{
        VerticesAdded = 0
        VerticesUpdated = 0
        VerticesDeleted = 0
        EdgesAdded = 0
        EdgesUpdated = 0
        EdgesDeleted = 0
        TotalRUs = 0
    }

    # Query changes container for recent deltas
    $changesQuery = @"
SELECT * FROM c
WHERE c.collectionTimestamp >= '$($Since.ToString("o"))'
ORDER BY c.collectionTimestamp ASC
"@

    $changes = Invoke-CosmosQuery -Container "changes" -Query $changesQuery

    # Group changes by type for ordering
    $principalChanges = $changes | Where-Object { $_.entityType -in @('users', 'groups', 'servicePrincipals', 'devices') }
    $resourceChanges = $changes | Where-Object { $_.entityType -in @('applications', 'directoryRoles', 'azureResources') }
    $edgeChanges = $changes | Where-Object { $_.entityType -eq 'edges' }

    #region Phase 1: Project Vertices (Principals + Resources)
    Write-Verbose "=== Phase 1: Projecting Vertices ==="

    foreach ($change in ($principalChanges + $resourceChanges)) {
        $label = switch ($change.entityType) {
            'users' { 'user' }
            'groups' { 'group' }
            'servicePrincipals' { 'servicePrincipal' }
            'devices' { 'device' }
            'applications' { 'application' }
            'directoryRoles' { 'directoryRole' }
            'azureResources' { $change.resourceType }  # Keep specific type
            default { $change.entityType }
        }

        if ($change.deleted -eq $true) {
            # Soft delete: Drop vertex (cascades to edges)
            $result = Remove-GraphVertex -ObjectId $change.objectId
            $stats.VerticesDeleted++
        }
        else {
            # Upsert vertex
            $properties = @{
                displayName = $change.displayName
                tenantId = $change.tenantId
                principalType = $change.principalType ?? $change.resourceType
                effectiveFrom = $change.effectiveFrom
            }

            $result = Add-GraphVertex -ObjectId $change.objectId -Label $label -Properties $properties

            if ($result.Results.Count -gt 0 -and $result.Results[0].id) {
                $stats.VerticesUpdated++
            }
            else {
                $stats.VerticesAdded++
            }
        }

        $stats.TotalRUs += $result.RequestCharge
    }
    #endregion

    #region Phase 2: Project Edges
    Write-Verbose "=== Phase 2: Projecting Edges ==="

    foreach ($change in $edgeChanges) {
        if ($change.deleted -eq $true) {
            # Soft delete: Drop edge
            $result = Remove-GraphEdge -SourceId $change.sourceId -TargetId $change.targetId -EdgeType $change.edgeType
            $stats.EdgesDeleted++
        }
        else {
            # Upsert edge
            $properties = @{
                effectiveFrom = $change.effectiveFrom
                sourceType = $change.sourceType
                targetType = $change.targetType
            }

            # Add edge-specific properties (e.g., requiresMfa for CA edges)
            if ($change.requiresMfa) { $properties.requiresMfa = $change.requiresMfa }
            if ($change.blocksAccess) { $properties.blocksAccess = $change.blocksAccess }
            if ($change.roleDefinitionName) { $properties.roleDefinitionName = $change.roleDefinitionName }

            $result = Add-GraphEdge `
                -SourceId $change.sourceId `
                -TargetId $change.targetId `
                -EdgeType $change.edgeType `
                -Properties $properties

            $stats.EdgesAdded++
        }

        $stats.TotalRUs += $result.RequestCharge
    }
    #endregion

    Write-Verbose "Projection complete: $($stats | ConvertTo-Json -Compress)"
    return $stats
}
```

### Vertex/Edge Deletion (Soft Delete Handling)

```powershell
function Remove-GraphVertex {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ObjectId
    )

    # Drop vertex (automatically drops connected edges)
    $query = "g.V('$ObjectId').drop()"

    return Submit-GremlinQuery -Query $query
}

function Remove-GraphEdge {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceId,

        [Parameter(Mandatory = $true)]
        [string]$TargetId,

        [Parameter(Mandatory = $true)]
        [string]$EdgeType
    )

    # Drop specific edge
    $query = @"
g.V('$SourceId')
  .outE('$EdgeType')
  .where(inV().hasId('$TargetId'))
  .drop()
"@

    return Submit-GremlinQuery -Query $query
}
```

---

## 3.6 RU Cost Optimization

### 1. Atomic Upserts

The `fold().coalesce()` pattern is a single atomic operation:
- **No read-before-write** - Avoids separate GET then PUT
- **Single round-trip** - One RU charge per operation
- **No overwrites** - Only writes if entity doesn't exist

### 2. Skip Unchanged Entities

If your delta detection indicates no changes to an entity's properties, skip the upsert:

```powershell
if ($change.changeType -eq 'noChange') {
    # Entity exists but unchanged - skip projection
    continue
}
```

### 3. Batch Operations (Future Optimization)

For large deltas, consider batching multiple operations:

```gremlin
// Chain multiple vertex upserts in single query
g.V('id1').fold().coalesce(unfold(), addV('user').property(id, 'id1'))
.V('id2').fold().coalesce(unfold(), addV('user').property(id, 'id2'))
.V('id3').fold().coalesce(unfold(), addV('group').property(id, 'id3'))
```

**Note:** Be careful with batching - Cosmos Gremlin has a 2MB request size limit.

### 4. Index Optimization

Ensure the Gremlin container has appropriate indexes:
- Vertex ID (automatic)
- Edge labels
- Commonly queried properties (`principalType`, `effectiveFrom`, etc.)

---

## 3.7 TinkerPop 3.6+ Alternative

If your Cosmos DB supports TinkerPop 3.6+, you can use the cleaner `mergeV()` / `mergeE()` syntax:

### Vertex Merge

```gremlin
g.mergeV([(T.id): 'user-123', (T.label): 'user'])
  .option(onCreate, [(displayName): 'John Doe', (principalType): 'user'])
  .option(onMatch, [(displayName): 'John Doe'])  // Update on match, or [] to skip
```

### Edge Merge

```gremlin
g.mergeE([(T.label): 'groupMember', (Direction.from): 'user-123', (Direction.to): 'group-456'])
  .option(onCreate, [(effectiveFrom): '2026-01-08'])
  .option(onMatch, [])  // Do nothing on match
```

**Compatibility Note:** As of January 2026, check if your Cosmos DB Gremlin API version supports `mergeV()`/`mergeE()`. The `fold().coalesce()` pattern is universally supported.

---

## 3.8 Function App Integration

### ProjectGraphToGremlin/run.ps1

```powershell
param($Timer)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

# Load Gremlin.Net
$gremlinDllPath = Join-Path $PSScriptRoot "lib\Gremlin.Net.dll"
if (Test-Path $gremlinDllPath) {
    Add-Type -Path $gremlinDllPath
}

try {
    Write-Information "Starting Gremlin projection..."

    # Project changes from the last hour (or since last run)
    $lastRun = $env:LAST_PROJECTION_RUN ?? (Get-Date).AddHours(-1)

    $stats = Invoke-GraphProjection -Since ([DateTime]$lastRun)

    # Update last run timestamp
    $env:LAST_PROJECTION_RUN = (Get-Date).ToString("o")

    Write-Information "Projection complete: Vertices +$($stats.VerticesAdded)/-$($stats.VerticesDeleted), Edges +$($stats.EdgesAdded)/-$($stats.EdgesDeleted), RUs: $($stats.TotalRUs)"

    return @{
        Success = $true
        Stats = $stats
    }
}
catch {
    Write-Error "Gremlin projection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
```

### ProjectGraphToGremlin/function.json

```json
{
  "bindings": [
    {
      "name": "Timer",
      "type": "timerTrigger",
      "direction": "in",
      "schedule": "0 */15 * * * *"
    }
  ]
}
```

---

# Part 4: Attack Path Queries

## 4.1 Gremlin Query Examples

### Find Paths to Global Admin

```gremlin
g.V().hasLabel('directoryRole').has('roleTemplateId', '62e90394-69f5-4237-9190-012177145e10')
  .repeat(__.in().simplePath())
  .emit()
  .limit(100)
  .path()
  .by(valueMap('displayName', 'principalType'))
```

### Find Paths Bypassing MFA

```gremlin
g.V().hasLabel('directoryRole').has('isPrivileged', true)
  .repeat(__.in().simplePath())
  .emit()
  .path()
  .where(
    not(__.unfold().outE('caPolicyTargetsPrincipal').has('requiresMfa', true))
  )
```

### Who Can Add Secrets to Apps?

```gremlin
g.V().hasLabel('application')
  .in('appOwner')
  .dedup()
  .valueMap('displayName', 'principalType')
```

### Azure Attack Path: User to Key Vault

```gremlin
g.V('user-id')
  .repeat(out().simplePath())
  .until(hasLabel('keyVault'))
  .limit(50)
  .path()
  .by(valueMap('displayName'))
```

### Find All Paths to Any Privileged Role

```gremlin
g.V().hasLabel('directoryRole').has('isPrivileged', true)
  .repeat(__.in().simplePath())
  .emit()
  .limit(100)
  .path()
```

### Users Excluded from MFA Policies

```gremlin
g.E().hasLabel('caPolicyExcludesPrincipal')
  .where(outV().has('requiresMfa', true))
  .inV()
  .dedup()
  .values('displayName')
```

---

## 4.2 Power BI SQL Query Patterns

### Users NOT Protected by MFA for a Specific App

```sql
SELECT p.displayName, p.userPrincipalName
FROM principals p
WHERE p.principalType = 'user'
  AND p.accountEnabled = true
  AND NOT EXISTS (
    SELECT 1 FROM edges e
    WHERE e.edgeType = 'caPolicyTargetsPrincipal'
      AND e.targetId = p.objectId
      AND e.requiresMfa = true
  )
```

### Coverage Gap: Apps Without MFA Protection

```sql
SELECT r.displayName as AppName, r.appId
FROM resources r
WHERE r.resourceType = 'application'
  AND NOT EXISTS (
    SELECT 1 FROM edges e
    WHERE e.edgeType = 'caPolicyTargetsApplication'
      AND (e.targetId = r.objectId OR e.targetId = 'All')
      AND e.requiresMfa = true
  )
```

### Users Excluded from MFA Policies

```sql
SELECT p.displayName, pol.displayName as ExcludingPolicy
FROM principals p
JOIN edges e ON e.targetId = p.objectId AND e.edgeType = 'caPolicyExcludesPrincipal'
JOIN policies pol ON pol.objectId = e.sourceId
WHERE e.requiresMfa = true AND pol.state = 'enabled'
```

### Privileged Roles and Their Members

```sql
SELECT r.displayName as RoleName, r.isPrivileged, COUNT(e.sourceId) as MemberCount
FROM resources r
LEFT JOIN edges e ON e.targetId = r.objectId AND e.edgeType = 'directoryRole'
WHERE r.resourceType = 'directoryRole'
GROUP BY r.objectId, r.displayName, r.isPrivileged
ORDER BY r.isPrivileged DESC, MemberCount DESC
```

---

# Implementation Tasks

## Task Order

| # | Task | Priority | Files |
|---|------|----------|-------|
| 1 | Add Phase 13 (CA edges + Named Locations) to CollectRelationships | High | CollectRelationships/run.ps1 |
| 2 | Add Phase 14 (Role Policy edges) to CollectRelationships | High | CollectRelationships/run.ps1 |
| 3 | Create CollectDirectoryRoleDefinitions | High | New collector |
| 4 | Create CollectAzureRoleDefinitions | High | New collector |
| 5 | Update Orchestrator for new collectors | High | Orchestrator/run.ps1 |
| 6 | Create ProjectGraphToGremlin function | Medium | New function |
| 7 | Update Dashboard with new edges count | Low | Dashboard/run.ps1 |
| 8 | Create CollectLicenseSkus (optional) | Low | New collector |

---

## New Files to Create

| File | Purpose |
|------|---------|
| `FunctionApp/CollectDirectoryRoleDefinitions/run.ps1` | Collect Entra role definitions |
| `FunctionApp/CollectDirectoryRoleDefinitions/function.json` | Function config |
| `FunctionApp/CollectAzureRoleDefinitions/run.ps1` | Collect Azure role definitions |
| `FunctionApp/CollectAzureRoleDefinitions/function.json` | Function config |
| `FunctionApp/ProjectGraphToGremlin/run.ps1` | Cosmos SQL → Gremlin API projection |
| `FunctionApp/ProjectGraphToGremlin/function.json` | Function config (timer trigger) |
| `FunctionApp/ProjectGraphToGremlin/lib/Gremlin.Net.dll` | Gremlin.Net library |

---

## Files to Modify

| File | Change |
|------|--------|
| `CollectRelationships/run.ps1` | Add Phase 13 for CA policy edges + location edges (~120 lines) |
| `CollectRelationships/run.ps1` | Add Phase 14 for role management policy edges (~80 lines) |
| `CollectRelationships/run.ps1` | Add `CaPolicyEdges` and `RolePolicyEdges` to stats tracking |
| `Orchestrator/run.ps1` | Add new collectors to Phase 1 |
| `Dashboard/run.ps1` | Add new edges count display |

---

# Validation Checklist

## CA Policy Edges (Phase 13)
- [ ] `CaPolicyEdges` stat added to CollectRelationships
- [ ] Phase 13 added to CollectRelationships
- [ ] `caPolicyTargetsPrincipal` edges created for included users/groups/roles
- [ ] `caPolicyTargetsApplication` edges created for included apps
- [ ] `caPolicyExcludesPrincipal` edges created for excluded users/groups/roles
- [ ] `caPolicyExcludesApplication` edges created for excluded apps
- [ ] Binary flags (requiresMfa, blocksAccess, etc.) populated correctly
- [ ] "All Users" / "All Apps" handled as special targetType values
- [ ] Directory roles in CA handled with targetType = "directoryRole"

## Named Location Edges (Phase 13)
- [ ] `caPolicyUsesLocation` edges created for includeLocations
- [ ] `caPolicyUsesLocation` edges created for excludeLocations (with `locationUsageType = "exclude"`)
- [ ] "All" and "AllTrusted" handled as special targetType values

## Role Management Policy Edges (Phase 14)
- [ ] `RolePolicyEdges` stat added to CollectRelationships
- [ ] Phase 14 added to CollectRelationships
- [ ] `rolePolicyAssignment` edges created for each role policy assignment
- [ ] `requiresMfaOnActivation` flag extracted correctly from enablement rules
- [ ] `requiresApproval` flag extracted correctly from approval rules
- [ ] `requiresJustification` flag extracted correctly
- [ ] `maxActivationDurationHours` extracted correctly

## Synthetic Vertices
- [ ] CollectDirectoryRoleDefinitions collector created
- [ ] Directory role definitions indexed to resources container
- [ ] `isPrivileged` flag set correctly on privileged roles
- [ ] CollectAzureRoleDefinitions collector created
- [ ] Azure role definitions indexed to resources container
- [ ] `isPrivileged` flag set correctly on privileged Azure roles
- [ ] Orchestrator calls new collectors in correct phase

## Gremlin Projection
- [ ] Gremlin.Net DLL included in function app
- [ ] Environment variables configured (endpoint, database, container, key)
- [ ] `Submit-GremlinQuery` handles retries and rate limiting
- [ ] `Add-GraphVertex` creates vertices with correct labels
- [ ] `Add-GraphEdge` creates edges between correct vertices
- [ ] Soft deletes handled (drop vertices/edges when `deleted = true`)
- [ ] Delta-driven projection reads from `changes` container
- [ ] Vertices projected before edges (dependency order)
- [ ] Attack path queries return expected results
- [ ] RU consumption within budget

---

# References

## Edge Types (V3.1 Additions)

| edgeType | Source | Target | New in V3.1? |
|----------|--------|--------|--------------|
| `caPolicyTargetsPrincipal` | CA Policy | User/Group/Role | Yes |
| `caPolicyTargetsApplication` | CA Policy | Application/SP | Yes |
| `caPolicyExcludesPrincipal` | CA Policy | User/Group/Role | Yes |
| `caPolicyExcludesApplication` | CA Policy | Application/SP | Yes |
| `caPolicyUsesLocation` | CA Policy | Named Location | Yes |
| `rolePolicyAssignment` | Role Mgmt Policy | Directory Role | Yes |

## Resource Types (V3.1 Additions)

| resourceType | Container | New in V3.1? |
|--------------|-----------|--------------|
| `directoryRole` | resources | Yes |
| `azureRoleDefinition` | resources | Yes |
| `licenseSku` | resources | Yes (optional) |

## External Documentation

- [Azure Cosmos DB Gremlin API Documentation](https://learn.microsoft.com/en-us/azure/cosmos-db/gremlin/)
- [Gremlin.Net GitHub](https://github.com/apache/tinkerpop/tree/master/gremlin-dotnet)
- [TinkerPop Gremlin Reference](https://tinkerpop.apache.org/docs/current/reference/)
- [Introduction to Azure Cosmos DB Gremlin API (Video)](https://www.youtube.com/watch?v=ClxefkVPJ18)

---

**End of V3.1 Graph Features Document**
