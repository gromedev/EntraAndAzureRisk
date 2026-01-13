#
# /Users/thomas/git/GitHub/EntraAndAzureRisk/docs/Epic 1-MSGraphPermissions-Integration-Plan.md
#
# Need to update to a version 5 after the above
#

# Technical Design Document: Edge Schema Optimization (V3.6)

**Version:** 4.0
**Status:** Final Draft
**Subject:** Refactoring the Unified Edge DTO to Resolve Property Bloat and Enable Security Enrichment

---

## 1. Executive Summary

The current V3.5 architecture uses a **Unified Edge Schema** with **87+ top-level fields** for every relationship. Testing on a 200-user tenant reveals:

| Issue | Impact |
|-------|--------|
| **~70% Null Density** | Storage waste, confusing dashboards |
| **O(n) Property Loading** | Gremlin traversal latency scales with field count |
| **Missing Security Enrichment** | `tier`/`severity` only on derived edges; membership edges lack policy context |

**Root Cause:** The collection phase captures topology (Source → Target) but lacks an enrichment phase to correlate membership edges with security policies.

**Solution:** This work is split into **two distinct epics**:

| Epic | Scope | Risk | Value |
|------|-------|------|-------|
| **Epic A: Schema Refactoring** | Migrate to Core + Properties nested model | Medium | Storage savings, cleaner data model |
| **Epic B: Security Enrichment** | Add `mfaProtected`, `tier`, `severity` to physical edges | High | Security visibility on attack paths |

This document covers **both epics** with Epic A as the primary implementation and Epic B as a documented extension.

---

## 2. Current State Analysis

### 2.1 Actual File Inventory

| Component | File Path |
|-----------|-----------|
| **Edge Collection** | `FunctionApp/CollectRelationships/run.ps1` |
| **Edge Indexer** | `FunctionApp/IndexEdgesInCosmosDB/run.ps1` |
| **Abuse Edge Derivation** | `FunctionApp/DeriveEdges/run.ps1` |
| **Virtual Edge Derivation** | `FunctionApp/DeriveVirtualEdges/run.ps1` |
| **Gremlin Projector** | `FunctionApp/ProjectGraphToGremlin/run.ps1` |
| **Gremlin Functions** | `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1` (lines 2653-2734) |
| **Indexer Config** | `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` (lines 950-1194) |
| **Dangerous Permissions** | `FunctionApp/DeriveEdges/DangerousPermissions.psd1` |

### 2.2 Edge Collection Phases (17 Total)

`CollectRelationships/run.ps1` has **17 phases**:

| # | Phase | Edge Type(s) Created |
|---|-------|---------------------|
| 1 | Group memberships (direct) | `groupMember` |
| 2 | Group memberships (transitive) | `groupMemberTransitive` |
| 3 | Directory role members | `directoryRole` |
| 4 | PIM eligible role assignments | `pimEligible` |
| 5 | PIM active role assignments | `pimActive` |
| 6 | PIM role requests | `pimRequest` |
| 7 | PIM group eligible memberships | `pimGroupEligible` |
| 8 | PIM group active memberships | `pimGroupActive` |
| 9 | Azure RBAC assignments | `azureRbac` |
| 10 | Application owners | `appOwner` |
| 11 | Service Principal owners | `spOwner` |
| 12 | User license assignments | `license` |
| 13 | OAuth2 permission grants | `oauth2PermissionGrant` |
| 14 | App role assignments | `appRoleAssignment` |
| 15 | Group owners | `groupOwner` |
| 16 | Device owners | `deviceOwner` |
| 17a | Conditional Access policy edges | `caPolicyTargetsPrincipal`, `caPolicyExcludesPrincipal`, `caPolicyTargetsApplication`, `caPolicyExcludesApplication`, `caPolicyUsesLocation` |
| 17b | Role management policy edges | `rolePolicyAssignment` |

### 2.3 MFA Field Clarification

**Critical clarification:** There are TWO distinct MFA-related fields with different semantics:

| Field | Where Populated | Meaning |
|-------|-----------------|---------|
| `requiresMfa` | CA Policy edges only (`caPolicyTargetsPrincipal`) | "This CA policy requires MFA as a grant control" |
| `requiresMfaOnActivation` | Role Policy edges only (`rolePolicyAssignment`) | "This PIM role requires MFA to activate" |

**The actual gap:** Neither field appears on **membership edges** (`groupMember`, `directoryRole`, etc.). The question "does this user-to-group edge require MFA?" requires correlating the membership with CA policies targeting that group - this is **enrichment**, not collection.

**Proposed Field:** `mfaProtected` (not `requiresMfa`) with clear semantics:
```
mfaProtected = true means:
"At least one enabled Conditional Access policy requires MFA
and targets the group/role that is the target of this edge"
```

### 2.4 Current Edge Schema (87+ Fields - ALL FLAT)

All 87+ fields exist at root level with no nested structure:

**Core Connectivity (8 fields):**
```
id, objectId, edgeType, sourceId, targetId, sourceType, targetType, collectionTimestamp
```

**Denormalized Source Fields (10 fields):**
```
sourceDisplayName, sourceUserPrincipalName, sourceAccountEnabled, sourceUserType,
sourceAppId, sourceServicePrincipalType, sourceSecurityEnabled, sourceMailEnabled,
sourceIsAssignableToRole
```

**Denormalized Target Fields (18 fields):**
```
targetDisplayName, targetSecurityEnabled, targetMailEnabled, targetVisibility,
targetIsAssignableToRole, targetRoleTemplateId, targetIsPrivileged, targetIsBuiltIn,
targetRoleDefinitionId, targetRoleDefinitionName, scope, scopeType, scopeDisplayName,
targetSkuId, targetSkuPartNumber, targetAppId, targetSignInAudience, targetPublisherDomain,
targetAppDisplayName, targetServicePrincipalType, targetAccountEnabled
```

**Relationship-Specific Fields (12 fields):**
```
membershipType, inheritancePath (array), inheritanceDepth, assignmentType, memberType,
status, scheduleInfo (embedded object), appRoleId, appRoleDisplayName, appRoleDescription,
resourceId, resourceDisplayName, consentType, permissionScope, assignmentSource,
inheritedFromGroupId, inheritedFromGroupName
```

**Conditional Access Policy Fields (11 fields):**
```
policyState, requiresMfa, blocksAccess, requiresCompliantDevice, requiresHybridAzureADJoin,
requiresApprovedApp, requiresAppProtection, clientAppTypes (array), hasLocationCondition,
hasRiskCondition, locationUsageType
```

**Role Management Policy Fields (7 fields):**
```
requiresMfaOnActivation, requiresApproval, requiresJustification, requiresTicketInfo,
maxActivationDurationHours, permanentAssignmentAllowed, eligibleAssignmentMaxDurationDays
```

**Derived/Abuse Edge Fields (8 fields):**
```
derivedFrom, derivedFromEdgeId, permissionName, severity, description, roleName,
roleTemplateId, tier, isRoleAssignableGroup
```

**Virtual Edge Fields (4 fields):**
```
sourcePlatform, assignmentFilterType, protectedAppCount, isExclusion
```

**Azure RBAC Fields (4 fields):**
```
subscriptionId, subscriptionName, resourceGroup, roleId
```

**Temporal Fields (2 fields):**
```
effectiveFrom, effectiveTo
```

### 2.5 Current Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         COLLECTION PHASE                                 │
├─────────────────────────────────────────────────────────────────────────┤
│  CollectRelationships/run.ps1                                           │
│  - 17 phases creating edges from Graph/ARM APIs                         │
│  - Creates FLAT hashtables with 87+ potential fields                    │
│  - Writes to edges.jsonl blob                                           │
│  - CA policy edges DO populate requiresMfa (for the policy itself)      │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         INDEXING PHASE                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  IndexEdgesInCosmosDB/run.ps1                                           │
│  - Calls Invoke-DeltaIndexingWithBinding                                │
│  - Compares against existing edges (delta detection)                    │
│  - Writes to Cosmos DB SQL (edges container)                            │
│  - Triggers Change Feed                                                 │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐
│     DERIVATION PHASE        │   │     PROJECTION PHASE        │
├─────────────────────────────┤   ├─────────────────────────────┤
│  DeriveEdges/run.ps1        │   │  ProjectGraphToGremlin/     │
│  - Creates abuse capability │   │  run.ps1                    │
│    edges (can*, is*, azure*)│   │  - Reads Change Feed        │
│  - ONLY place severity/tier │   │  - Calls Add-GraphEdge      │
│    are populated            │   │  - Passes properties to     │
│                             │   │    Gremlin (flattened)      │
│  DeriveVirtualEdges/run.ps1 │   │                             │
│  - Creates policy gate edges│   │                             │
└─────────────────────────────┘   └─────────────────────────────┘
```

**The Gap:** There is no phase that correlates membership edges with CA policies to answer: "When this user accesses resources via this group membership, will they be challenged for MFA?"

---

## 3. Epic A: Schema Refactoring (Core + Properties Model)

### 3.1 New Edge Document Structure

| Level | Field | Type | Purpose |
|-------|-------|------|---------|
| **Root** | `id` | String | Composite key: `sourceId_targetId_edgeType` |
| **Root** | `objectId` | String | Same as id (legacy compatibility) |
| **Root** | `edgeType` | String | Partition key / discriminator |
| **Root** | `sourceId` | UUID | Source vertex ID |
| **Root** | `targetId` | UUID | Target vertex ID |
| **Root** | `sourceType` | String | Entity class (user, servicePrincipal, group) |
| **Root** | `targetType` | String | Entity class (group, directoryRole, azureResource) |
| **Root** | `collectionTimestamp` | DateTime | Ingestion time |
| **Root** | `deleted` | Boolean | Soft-delete marker |
| **Root** | `schemaVersion` | Integer | Schema version (2 = nested) |
| **Nested** | `properties` | Object | Type-specific metadata (non-null only) |

### 3.2 Field Classification

**Core Fields (remain at root - 11 fields):**
```powershell
$CoreFields = @(
    "id"
    "objectId"
    "edgeType"
    "sourceId"
    "targetId"
    "sourceType"
    "targetType"
    "collectionTimestamp"
    "deleted"
    "partitionKey"
    "schemaVersion"
)
```

**Properties Fields (move to nested object - 77+ fields):**
All other fields move into `properties`, but **only if non-null/non-empty**.

### 3.3 JSON Examples

**Before (Current - Flat with nulls):**
```json
{
  "id": "user123_group456_groupMember",
  "objectId": "user123_group456_groupMember",
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "group456",
  "sourceType": "user",
  "targetType": "group",
  "sourceDisplayName": "John Doe",
  "sourceUserPrincipalName": "john@contoso.com",
  "sourceAccountEnabled": true,
  "targetDisplayName": "Sales Team",
  "targetSecurityEnabled": true,
  "membershipType": "Direct",
  "severity": null,
  "tier": null,
  "requiresMfa": null,
  "subscriptionId": null,
  "collectionTimestamp": "2026-01-13T10:00:00Z"
}
```

**After (Proposed - Nested, no nulls):**
```json
{
  "id": "user123_group456_groupMember",
  "objectId": "user123_group456_groupMember",
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "group456",
  "sourceType": "user",
  "targetType": "group",
  "collectionTimestamp": "2026-01-13T10:00:00Z",
  "deleted": false,
  "schemaVersion": 2,
  "properties": {
    "sourceDisplayName": "John Doe",
    "sourceUserPrincipalName": "john@contoso.com",
    "sourceAccountEnabled": true,
    "targetDisplayName": "Sales Team",
    "targetSecurityEnabled": true,
    "membershipType": "Direct",
    "inheritanceDepth": 0
  }
}
```

**After Enrichment (Epic B):**
```json
{
  "id": "user123_group456_groupMember",
  "objectId": "user123_group456_groupMember",
  "edgeType": "groupMember",
  "sourceId": "user123",
  "targetId": "group456",
  "sourceType": "user",
  "targetType": "group",
  "collectionTimestamp": "2026-01-13T10:00:00Z",
  "deleted": false,
  "schemaVersion": 2,
  "properties": {
    "sourceDisplayName": "John Doe",
    "sourceUserPrincipalName": "john@contoso.com",
    "sourceAccountEnabled": true,
    "targetDisplayName": "Sales Team",
    "targetSecurityEnabled": true,
    "membershipType": "Direct",
    "mfaProtected": true,
    "tier": 1,
    "severity": "Medium"
  }
}
```

---

## 4. Epic A Implementation

### 4.1 Phase 0: Proof of Concept (Single Edge Type)

**Objective:** Validate the approach with minimal risk before touching all 17 phases.

**Scope:** Implement nested schema for `groupMember` edges only.

**Success Criteria:**
- [ ] `groupMember` edges stored with nested schema
- [ ] Existing flat edges continue to work
- [ ] Gremlin queries return correct results for both schemas
- [ ] Dashboard displays data correctly
- [ ] Delta indexing detects changes in nested properties

### 4.2 Phase 1: Add Helper Functions to Module

**File:** `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1`

```powershell
function New-EdgeDocument {
    <#
    .SYNOPSIS
        Creates a new edge document with nested properties structure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceId,

        [Parameter(Mandatory)]
        [string]$TargetId,

        [Parameter(Mandatory)]
        [string]$EdgeType,

        [Parameter(Mandatory)]
        [string]$SourceType,

        [Parameter(Mandatory)]
        [string]$TargetType,

        [Parameter(Mandatory)]
        [hashtable]$Properties,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [Parameter()]
        [string]$IdSuffix  # Optional suffix for edge ID uniqueness
    )

    # Filter out null/empty properties
    $cleanProperties = [ordered]@{}
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -ne $value -and $value -ne '') {
            if ($value -is [array]) {
                if ($value.Count -gt 0) {
                    $cleanProperties[$key] = $value
                }
            }
            else {
                $cleanProperties[$key] = $value
            }
        }
    }

    # Build edge ID
    $edgeId = if ($IdSuffix) {
        "${SourceId}_${TargetId}_${EdgeType}_${IdSuffix}"
    }
    else {
        "${SourceId}_${TargetId}_${EdgeType}"
    }

    return [ordered]@{
        id                  = $edgeId
        objectId            = $edgeId
        edgeType            = $EdgeType
        sourceId            = $SourceId
        targetId            = $TargetId
        sourceType          = $SourceType
        targetType          = $TargetType
        collectionTimestamp = $Timestamp
        deleted             = $false
        schemaVersion       = 2
        properties          = $cleanProperties
    }
}

function ConvertTo-NestedEdge {
    <#
    .SYNOPSIS
        Converts a flat edge document to nested properties format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$FlatEdge
    )

    begin {
        $CoreFields = @(
            "id", "objectId", "edgeType", "sourceId", "targetId",
            "sourceType", "targetType", "collectionTimestamp",
            "deleted", "partitionKey", "schemaVersion", "lastModified",
            "_rid", "_self", "_etag", "_attachments", "_ts"
        )
    }

    process {
        $nested = [ordered]@{
            id                  = $FlatEdge.id
            objectId            = $FlatEdge.objectId
            edgeType            = $FlatEdge.edgeType
            sourceId            = $FlatEdge.sourceId
            targetId            = $FlatEdge.targetId
            sourceType          = $FlatEdge.sourceType
            targetType          = $FlatEdge.targetType
            collectionTimestamp = $FlatEdge.collectionTimestamp
            deleted             = $FlatEdge.deleted ?? $false
            schemaVersion       = 2
            properties          = [ordered]@{}
        }

        foreach ($prop in $FlatEdge.PSObject.Properties) {
            if ($prop.Name -notin $CoreFields) {
                $value = $prop.Value
                if ($null -ne $value -and $value -ne '') {
                    if ($value -is [array]) {
                        if ($value.Count -gt 0) {
                            $nested.properties[$prop.Name] = $value
                        }
                    }
                    else {
                        $nested.properties[$prop.Name] = $value
                    }
                }
            }
        }

        [PSCustomObject]$nested
    }
}

function Get-EdgeProperties {
    <#
    .SYNOPSIS
        Extracts properties from an edge, handling both schema versions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Edge
    )

    $CoreFields = @(
        "id", "objectId", "edgeType", "sourceId", "targetId",
        "sourceType", "targetType", "collectionTimestamp",
        "deleted", "partitionKey", "schemaVersion", "lastModified",
        "_rid", "_self", "_etag", "_attachments", "_ts"
    )

    if ($Edge.schemaVersion -eq 2 -and $Edge.properties) {
        # Nested schema - return properties directly
        if ($Edge.properties -is [hashtable]) {
            return $Edge.properties
        }
        else {
            # Convert PSCustomObject to hashtable
            $props = @{}
            foreach ($p in $Edge.properties.PSObject.Properties) {
                $props[$p.Name] = $p.Value
            }
            return $props
        }
    }
    else {
        # Flat schema - extract non-core fields
        $props = @{}
        foreach ($prop in $Edge.PSObject.Properties) {
            if ($prop.Name -notin $CoreFields -and $prop.Name -ne 'properties') {
                $props[$prop.Name] = $prop.Value
            }
        }
        return $props
    }
}
```

### 4.3 Phase 2: Update IndexerConfigs.psd1

**File:** `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1`

```powershell
edges = @{
    EntityType           = 'edges'
    EntityNameSingular   = 'edge'
    EntityNamePlural     = 'Edges'

    CompareFields = @(
        'edgeType'
        'sourceId'
        'targetId'
        'sourceType'
        'targetType'
        'deleted'
        'schemaVersion'
        'properties'  # Compare entire properties object
    )

    ArrayFields = @()  # Arrays now inside properties

    EmbeddedObjectFields = @(
        'properties'
        'scheduleInfo'  # Still embedded, but inside properties
    )

    DocumentFields = @{
        id                  = 'id'
        objectId            = 'objectId'
        edgeType            = 'edgeType'
        sourceId            = 'sourceId'
        targetId            = 'targetId'
        sourceType          = 'sourceType'
        targetType          = 'targetType'
        collectionTimestamp = 'collectionTimestamp'
        deleted             = 'deleted'
        schemaVersion       = 'schemaVersion'
        properties          = 'properties'
    }

    WriteDeletes         = $true
    IncludeDeleteMarkers = $true
    RawOutBinding        = 'edgesRawOut'
    ChangesOutBinding    = 'edgeChangesOut'
}
```

### 4.4 Phase 3: Update CollectRelationships (All 17 Phases)

Below are before/after transformations for every edge-creating phase.

---

#### Collection Phase 1: Direct Group Memberships

**Edge Type:** `groupMember`
**Source:** user, group, servicePrincipal, device → **Target:** group

**Current (Flat):**
```powershell
$relationship = @{
    id = "$($member.id)_$($group.id)_groupMember"
    objectId = "$($member.id)_$($group.id)_groupMember"
    edgeType = "groupMember"
    sourceId = $member.id
    sourceType = $memberType
    sourceDisplayName = $member.displayName ?? ""
    targetId = $group.id
    targetType = "group"
    targetDisplayName = $group.displayName ?? ""
    sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName ?? $null } else { $null }
    sourceAccountEnabled = if ($null -ne $member.accountEnabled) { $member.accountEnabled } else { $null }
    targetSecurityEnabled = $group.securityEnabled ?? $null
    targetMailEnabled = $group.mailEnabled ?? $null
    targetIsAssignableToRole = $group.isAssignableToRole ?? $false
    membershipType = "Direct"
    inheritancePath = @()
    inheritanceDepth = 0
    collectionTimestamp = $timestampFormatted
}
```

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $member.id `
    -TargetId $group.id `
    -EdgeType "groupMember" `
    -SourceType $memberType `
    -TargetType "group" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName       = $member.displayName
        targetDisplayName       = $group.displayName
        sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName } else { $null }
        sourceAccountEnabled    = $member.accountEnabled
        targetSecurityEnabled   = $group.securityEnabled
        targetMailEnabled       = $group.mailEnabled
        targetIsAssignableToRole = $group.isAssignableToRole
        membershipType          = "Direct"
        inheritanceDepth        = 0
    }
```

---

#### Collection Phase 2: Transitive Group Memberships

**Edge Type:** `groupMemberTransitive`
**Special:** `inheritancePath` is an array of group IDs

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $member.id `
    -TargetId $group.id `
    -EdgeType "groupMemberTransitive" `
    -SourceType $memberType `
    -TargetType "group" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName       = $member.displayName
        targetDisplayName       = $group.displayName
        sourceUserPrincipalName = if ($memberType -eq 'user') { $member.userPrincipalName } else { $null }
        sourceAccountEnabled    = $member.accountEnabled
        targetSecurityEnabled   = $group.securityEnabled
        targetIsAssignableToRole = $group.isAssignableToRole
        membershipType          = "Transitive"
        inheritancePath         = $pathArray
        inheritanceDepth        = $pathArray.Count
    }
```

---

#### Collection Phase 3: Directory Role Assignments

**Edge Type:** `directoryRole`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $assignment.principalId `
    -TargetId $assignment.roleDefinitionId `
    -EdgeType "directoryRole" `
    -SourceType "" `
    -TargetType "directoryRole" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName     = ""  # Enriched later
        targetDisplayName     = $roleDef.displayName
        targetRoleTemplateId  = $roleDef.templateId
        targetIsPrivileged    = $isPrivileged
        targetIsBuiltIn       = $roleDef.isBuiltIn
        directoryScopeId      = $assignment.directoryScopeId
        isScopedAssignment    = ($assignment.directoryScopeId -ne "/")
    }
```

---

#### Collection Phase 4-5: PIM Role Assignments (Eligible/Active)

**Edge Types:** `pimEligible`, `pimActive`
**Special:** `scheduleInfo` is an embedded object

**Proposed (Nested) - Eligible:**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $schedule.principalId `
    -TargetId $schedule.roleDefinitionId `
    -EdgeType "pimEligible" `
    -SourceType "" `
    -TargetType "directoryRole" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName      = ""
        targetDisplayName      = $roleDef.displayName
        assignmentType         = "eligible"
        targetRoleTemplateId   = $roleDef.templateId
        targetIsPrivileged     = $true
        memberType             = $schedule.memberType
        status                 = $schedule.status
        scheduleInfo           = @{
            startDateTime = $schedule.scheduleInfo.startDateTime
            expiration    = $schedule.scheduleInfo.expiration
        }
    }
```

---

#### Collection Phase 6: PIM Role Requests

**Edge Type:** `pimRequest`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $request.principalId `
    -TargetId $request.roleDefinitionId `
    -EdgeType "pimRequest" `
    -SourceType $principalType `
    -TargetType "directoryRole" `
    -Timestamp $timestampFormatted `
    -IdSuffix $request.id `
    -Properties @{
        sourceDisplayName      = $principal.displayName
        targetDisplayName      = $roleDef.displayName
        targetRoleTemplateId   = $roleDef.templateId
        action                 = $request.action
        status                 = $request.status
        justification          = $request.justification
        createdDateTime        = $request.createdDateTime
        scheduleInfo           = $request.scheduleInfo
        createdBy              = $request.createdBy
    }
```

---

#### Collection Phase 7-8: PIM Group Memberships (Eligible/Active)

**Edge Types:** `pimGroupEligible`, `pimGroupActive`

**Proposed (Nested) - Eligible:**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $schedule.principalId `
    -TargetId $group.id `
    -EdgeType "pimGroupEligible" `
    -SourceType $principalType `
    -TargetType "group" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName        = $principal.displayName
        targetDisplayName        = $group.displayName
        assignmentType           = "eligible"
        targetIsAssignableToRole = $true
        accessId                 = $schedule.accessId
        memberType               = $schedule.memberType
        status                   = $schedule.status
        scheduleInfo             = @{
            startDateTime = $schedule.scheduleInfo.startDateTime
            expiration    = $schedule.scheduleInfo.expiration
        }
    }
```

---

#### Collection Phase 9: Azure RBAC Assignments

**Edge Type:** `azureRbac`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $assignment.properties.principalId `
    -TargetId $roleDefId `
    -EdgeType "azureRbac" `
    -SourceType ($assignment.properties.principalType ?? "") `
    -TargetType "azureRole" `
    -Timestamp $timestampFormatted `
    -IdSuffix $subscriptionId `
    -Properties @{
        sourceDisplayName        = ""  # Enriched later
        targetDisplayName        = $roleDefName
        targetRoleDefinitionId   = $roleDefId
        targetRoleDefinitionName = $roleDefName
        subscriptionId           = $subscriptionId
        subscriptionName         = $subscription.displayName
        scope                    = $assignment.properties.scope
        scopeType                = $scopeType
        scopeDisplayName         = $scopeDisplayName
        resourceGroup            = $resourceGroup
    }
```

---

#### Collection Phase 10-11: Application/Service Principal Owners

**Edge Types:** `appOwner`, `spOwner`

**Proposed (Nested) - App Owner:**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $owner.id `
    -TargetId $app.id `
    -EdgeType "appOwner" `
    -SourceType $ownerType `
    -TargetType "application" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName       = $owner.displayName
        sourceUserPrincipalName = if ($ownerType -eq 'user') { $owner.userPrincipalName } else { $null }
        targetDisplayName       = $app.displayName
        targetAppId             = $app.appId
        targetSignInAudience    = $app.signInAudience
        targetPublisherDomain   = $app.publisherDomain
    }
```

---

#### Collection Phase 12: License Assignments

**Edge Type:** `license`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $user.id `
    -TargetId $license.skuId `
    -EdgeType "license" `
    -SourceType "user" `
    -TargetType "license" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName       = $user.displayName
        sourceUserPrincipalName = $user.userPrincipalName
        sourceAccountEnabled    = $user.accountEnabled
        targetDisplayName       = $skuLookup[$license.skuId]
        targetSkuId             = $license.skuId
        targetSkuPartNumber     = $license.skuPartNumber
        assignmentSource        = "direct"
    }
```

---

#### Collection Phase 13: OAuth2 Permission Grants

**Edge Type:** `oauth2PermissionGrant`
**Special:** AllPrincipals consent uses special sourceId

**Proposed (Nested):**
```powershell
# User consent
$relationship = New-EdgeDocument `
    -SourceId $grant.principalId `
    -TargetId $grant.resourceId `
    -EdgeType "oauth2PermissionGrant" `
    -SourceType "user" `
    -TargetType "servicePrincipal" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName  = $userLookup[$grant.principalId].displayName
        targetDisplayName  = $spLookup[$grant.resourceId].displayName
        clientId           = $grant.clientId
        clientDisplayName  = $spLookup[$grant.clientId].displayName
        consentType        = $grant.consentType
        scope              = $grant.scope
    }
```

---

#### Collection Phase 14: App Role Assignments

**Edge Type:** `appRoleAssignment`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $assignment.principalId `
    -TargetId $assignment.resourceId `
    -EdgeType "appRoleAssignment" `
    -SourceType $assignment.principalType `
    -TargetType "servicePrincipal" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName   = $assignment.principalDisplayName
        targetDisplayName   = $sp.displayName
        targetAppId         = $sp.appId
        appRoleId           = $assignment.appRoleId
        appRoleDisplayName  = $appRoleLookup[$assignment.appRoleId].displayName
        appRoleValue        = $appRoleLookup[$assignment.appRoleId].value
        createdDateTime     = $assignment.createdDateTime
    }
```

---

#### Collection Phase 15: Group Owners

**Edge Type:** `groupOwner`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $owner.id `
    -TargetId $group.id `
    -EdgeType "groupOwner" `
    -SourceType $ownerType `
    -TargetType "group" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName        = $owner.displayName
        sourceUserPrincipalName  = if ($ownerType -eq 'user') { $owner.userPrincipalName } else { $null }
        targetDisplayName        = $group.displayName
        targetSecurityEnabled    = $group.securityEnabled
        targetIsAssignableToRole = $group.isAssignableToRole
    }
```

---

#### Collection Phase 16: Device Owners

**Edge Type:** `deviceOwner`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $owner.id `
    -TargetId $device.id `
    -EdgeType "deviceOwner" `
    -SourceType "user" `
    -TargetType "device" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName       = $owner.displayName
        sourceUserPrincipalName = $owner.userPrincipalName
        targetDisplayName       = $device.displayName
        targetDeviceId          = $device.deviceId
        targetOperatingSystem   = $device.operatingSystem
        targetTrustType         = $device.trustType
    }
```

---

#### Collection Phase 17a: Conditional Access Policy Edges

**Edge Types:** `caPolicyTargetsPrincipal`, `caPolicyExcludesPrincipal`, `caPolicyTargetsApplication`, `caPolicyExcludesApplication`, `caPolicyUsesLocation`

**Common properties:**
```powershell
$policyProperties = @{
    sourceDisplayName         = $policy.displayName
    policyState               = $policy.state
    requiresMfa               = ($policy.grantControls.builtInControls -contains 'mfa')
    blocksAccess              = ($policy.grantControls.builtInControls -contains 'block')
    requiresCompliantDevice   = ($policy.grantControls.builtInControls -contains 'compliantDevice')
    clientAppTypes            = $policy.conditions.clientAppTypes
    hasLocationCondition      = ($null -ne $policy.conditions.locations)
    hasRiskCondition          = ($null -ne $policy.conditions.userRiskLevels)
}
```

**Proposed (Nested) - Principal Target:**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $policy.id `
    -TargetId $userId `
    -EdgeType "caPolicyTargetsPrincipal" `
    -SourceType "conditionalAccessPolicy" `
    -TargetType "user" `
    -Timestamp $timestampFormatted `
    -Properties ($policyProperties + @{
        targetDisplayName = $userLookup[$userId].displayName
    })
```

---

#### Collection Phase 17b: Role Management Policy Edges

**Edge Type:** `rolePolicyAssignment`

**Proposed (Nested):**
```powershell
$relationship = New-EdgeDocument `
    -SourceId $policy.id `
    -TargetId $roleDefId `
    -EdgeType "rolePolicyAssignment" `
    -SourceType "roleManagementPolicy" `
    -TargetType "directoryRole" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName              = $policy.displayName
        targetDisplayName              = $roleDef.displayName
        requiresMfaOnActivation        = $requiresMfa
        requiresApproval               = $requiresApproval
        requiresJustification          = $requiresJustification
        requiresTicketInfo             = $requiresTicket
        maxActivationDurationHours     = $maxHours
        permanentAssignmentAllowed     = $permanentAllowed
        eligibleAssignmentMaxDurationDays = $eligibleMaxDays
    }
```

---

### 4.5 Phase 4: Update DeriveEdges/run.ps1

**File:** `FunctionApp/DeriveEdges/run.ps1`

DeriveEdges reads from physical edges to create abuse capability edges. It currently accesses flat properties like `$edge.sourceDisplayName`, `$edge.appRoleId`. Must be updated to use `Get-EdgeProperties`.

**Current (reads flat):**
```powershell
foreach ($edge in $appRoleEdges) {
    $appRoleId = $edge.appRoleId
    ...
    $abuseEdge = @{
        sourceDisplayName = $edge.sourceDisplayName ?? ""
        sourceUserPrincipalName = $edge.sourceUserPrincipalName
        ...
    }
}
```

**Proposed (schema-aware):**
```powershell
foreach ($edge in $appRoleEdges) {
    $props = Get-EdgeProperties -Edge $edge
    $appRoleId = $props.appRoleId
    ...
    $abuseEdge = New-EdgeDocument `
        -SourceId $edge.sourceId `
        -TargetId $permInfo.TargetType `
        -EdgeType $permInfo.AbuseEdge `
        -SourceType ($edge.sourceType ?? "") `
        -TargetType "virtual" `
        -Timestamp $timestampFormatted `
        -Properties @{
            sourceDisplayName       = $props.sourceDisplayName
            targetDisplayName       = $permInfo.TargetType
            derivedFrom             = "appRoleAssignment"
            derivedFromEdgeId       = $edge.objectId
            permissionName          = $permInfo.Name
            severity                = $permInfo.Severity
            description             = $permInfo.Description
            sourceUserPrincipalName = $props.sourceUserPrincipalName
            sourceAccountEnabled    = $props.sourceAccountEnabled
            sourceAppId             = $props.sourceAppId
        }
}
```

**Phases to update in DeriveEdges:**
- Phase 1: Graph Permission Abuse (appRoleAssignment → can*)
- Phase 2: Directory Role Abuse (directoryRole → is*)
- Phase 3: Ownership Abuse (appOwner/spOwner/groupOwner → canAddSecret, etc.)
- Phase 4: Azure RBAC Abuse (azureRbac → azure*)

---

### 4.6 Phase 5: Update DeriveVirtualEdges/run.ps1

**File:** `FunctionApp/DeriveVirtualEdges/run.ps1`

DeriveVirtualEdges reads from **policies** (not edges), so it doesn't need `Get-EdgeProperties`. However, the edges it **creates** should use the nested schema.

**Proposed (nested output):**
```powershell
$virtualEdge = New-EdgeDocument `
    -SourceId $policy.objectId `
    -TargetId $assignment.groupId `
    -EdgeType "compliancePolicyTargets" `
    -SourceType "compliancePolicy" `
    -TargetType "group" `
    -Timestamp $timestampFormatted `
    -Properties @{
        sourceDisplayName    = $policy.displayName
        targetDisplayName    = $groupLookup[$assignment.groupId]
        sourcePlatform       = $policy.platform
        assignmentFilterType = $assignment.filterType
        isExclusion          = ($assignment.targetType -match 'exclusion')
    }
```

---

### 4.7 Phase 6: Update Module Manifest

**File:** `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psd1`

Add new functions to the module export list:

```powershell
FunctionsToExport = @(
    # ... existing functions ...
    'New-EdgeDocument'
    'ConvertTo-NestedEdge'
    'Get-EdgeProperties'
)
```

---

### 4.8 Phase 7: Update Gremlin Projector

**File:** `FunctionApp/ProjectGraphToGremlin/run.ps1`

**Key Point:** Properties are **flattened** during projection, so existing Gremlin queries continue to work.

```powershell
foreach ($change in $edgeChanges) {
    $edgeParts = $change.objectId -split '_'
    $sourceId = $edgeParts[0]
    $targetId = $edgeParts[1]
    $edgeType = $edgeParts[2..($edgeParts.Count - 1)] -join '_'

    # Extract properties using schema-aware function
    $props = Get-EdgeProperties -Edge $change

    # Handle delta changes
    if ($change.delta -and $change.schemaVersion -eq 2 -and $change.delta.properties) {
        $newProps = $change.delta.properties.new
        if ($newProps) {
            foreach ($key in $newProps.Keys) {
                $props[$key] = $newProps[$key]
            }
        }
    }

    # Project to Gremlin (properties flattened here)
    Add-GraphEdge -SourceId $sourceId -TargetId $targetId `
        -EdgeType $edgeType -Properties $props
}
```

---

## 5. Epic B: Security Enrichment

### 5.1 Overview

Epic B adds security metadata to physical edges:

| Enrichment | Question Answered | Data Source |
|------------|-------------------|-------------|
| `mfaProtected` | "Is access via this edge protected by MFA?" | CA Policies targeting the group/role |
| `tier` | "What tier is the target of this edge?" | Role template mapping, group classification |
| `severity` | "How critical is this edge for attack paths?" | Tier + edge type heuristics |

### 5.2 Implementation Phases

**Phase 1 (Implement Now):**

| Edge Type | Enrichment | Rule |
|-----------|------------|------|
| `groupMember` | `mfaProtected` | Target group is in CA policy with MFA grant control |
| `directoryRole` | `tier`, `severity` | Role template ID matches Tier 0/1/2 classification |

**Phase 2+ (Document Only, Implement Later):**

| Edge Type | Enrichment | Rule |
|-----------|------------|------|
| `pimEligible` | `requiresMfaOnActivation` | Cross-join with `rolePolicyAssignment` edges |
| `pimActive` | `tier`, `severity` | Same as `directoryRole` |
| `groupOwner` | `tier` | If target `isAssignableToRole` = true, mark as Tier 0 |
| `azureRbac` | `severity` | Owner/Contributor = Critical, Reader = Low |
| `appOwner` | `severity` | If target app has dangerous Graph permissions |

### 5.3 Tier Classification Reference

**Tier 0 (Critical) - Compromise means full tenant control:**
```powershell
$Tier0Roles = @(
    "62e90394-69f5-4237-9190-012177145e10"  # Global Administrator
    "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"  # Application Administrator
    "7be44c8a-adaf-4e2a-84d6-ab2649e08a13"  # Privileged Authentication Administrator
    "e8611ab8-c189-46e8-94e1-60213ab1f814"  # Privileged Role Administrator
    "194ae4cb-b126-40b2-bd5b-6091b380977d"  # Security Administrator
    "158c047a-c907-4556-b7ef-446551a6b5f7"  # Cloud Application Administrator
)
```

**Tier 1 (High) - Can escalate to Tier 0:**
```powershell
$Tier1Roles = @(
    "fe930be7-5e62-47db-91af-98c3a49a38b1"  # User Administrator
    "c4e39bd9-1100-46d3-8c65-fb160da0071f"  # Authentication Administrator
    "fdd7a751-b60b-444a-984c-02652fe8fa1c"  # Groups Administrator
    "29232cdf-9323-42fd-ade2-1d097af3e4de"  # Exchange Administrator
    "f28a1f50-f6e7-4571-818b-6a12f2af6b6c"  # SharePoint Administrator
    "966707d0-3269-4727-9be2-8c3a10f19b9d"  # Password Administrator
)
```

**Azure RBAC Severity:**
```powershell
$CriticalAzureRoles = @(
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"  # Owner
    "b24988ac-6180-42a0-ab88-20f7382dd24c"  # Contributor
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"  # User Access Administrator
)
```

### 5.4 Enrichment Function

**File:** `FunctionApp/EnrichEdges/run.ps1` (NEW)

```powershell
param($edgesIn, $policiesIn, $principalsIn, $edgesOut)

$timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"

# Build MFA lookup from CA policies
$MfaProtectedGroups = @{}
foreach ($policy in $policiesIn) {
    if ($policy.state -ne 'enabled') { continue }
    $requiresMfa = $policy.grantControls.builtInControls -contains 'mfa'
    if (-not $requiresMfa) { continue }

    foreach ($groupId in $policy.conditions.users.includeGroups) {
        $MfaProtectedGroups[$groupId] = $true
    }
}

# Enrich edges
$enrichedEdges = @()
foreach ($edge in $edgesIn) {
    $props = Get-EdgeProperties -Edge $edge
    $enriched = $false

    # MFA Enrichment for group memberships
    if ($edge.edgeType -in @('groupMember', 'groupMemberTransitive') -and
        $MfaProtectedGroups.ContainsKey($edge.targetId)) {
        $props.mfaProtected = $true
        $enriched = $true
    }

    # Tier Enrichment for directory roles
    if ($edge.edgeType -eq 'directoryRole') {
        $roleTemplateId = $props.targetRoleTemplateId
        if ($roleTemplateId -in $Tier0Roles) {
            $props.tier = 0
            $props.severity = "Critical"
            $enriched = $true
        }
        elseif ($roleTemplateId -in $Tier1Roles) {
            $props.tier = 1
            $props.severity = "High"
            $enriched = $true
        }
    }

    if ($enriched) {
        $edge.properties = $props
        $edge.lastModified = $timestamp
        $enrichedEdges += $edge
    }
}

Push-OutputBinding -Name edgesOut -Value $enrichedEdges
```

---

## 6. Dashboard Impact Analysis

### 6.1 SQL Query Changes Required

**Before (flat schema):**
```sql
SELECT c.sourceDisplayName, c.severity FROM c WHERE c.edgeType = 'groupMember'
```

**After (nested schema):**
```sql
SELECT c.properties.sourceDisplayName, c.properties.severity
FROM c WHERE c.edgeType = 'groupMember'
```

### 6.2 Schema-Aware Helper

```javascript
function getEdgeProperty(edge, propertyName) {
    if (edge.schemaVersion === 2) {
        return edge.properties?.[propertyName];
    }
    return edge[propertyName];
}
```

---

## 7. Migration Strategy

### 7.1 Rollout Phases

1. **POC:** Implement for `groupMember` only, test in dev
2. **Staged:** Enable remaining edge types one category at a time
3. **Full Migration:** Run backfill script for existing edges
4. **Cleanup:** Remove legacy flat schema support (optional)

### 7.2 Backfill Script

```powershell
param($edgesIn, $edgesOut)

$migrated = [System.Collections.ArrayList]::new()

foreach ($edge in $edgesIn) {
    if ($edge.schemaVersion -eq 2) { continue }

    $nested = $edge | ConvertTo-NestedEdge
    [void]$migrated.Add($nested)
}

Push-OutputBinding -Name edgesOut -Value $migrated.ToArray()
```

---

## 8. Edge Type Summary

| Phase | Edge Type | Source Type | Target Type | Key Properties |
|-------|-----------|-------------|-------------|----------------|
| 1 | `groupMember` | user/group/sp/device | group | membershipType |
| 2 | `groupMemberTransitive` | user/group/sp/device | group | inheritancePath |
| 3 | `directoryRole` | any | directoryRole | targetRoleTemplateId |
| 4 | `pimEligible` | any | directoryRole | scheduleInfo |
| 5 | `pimActive` | any | directoryRole | scheduleInfo |
| 6 | `pimRequest` | any | directoryRole | justification |
| 7 | `pimGroupEligible` | any | group | accessId |
| 8 | `pimGroupActive` | any | group | accessId |
| 9 | `azureRbac` | any | azureRole | subscriptionId, scope |
| 10 | `appOwner` | user/sp/group | application | targetAppId |
| 11 | `spOwner` | user/sp/group | servicePrincipal | targetAppId |
| 12 | `license` | user | license | targetSkuId |
| 13 | `oauth2PermissionGrant` | user/tenant | servicePrincipal | consentType, scope |
| 14 | `appRoleAssignment` | sp/user/group | servicePrincipal | appRoleId |
| 15 | `groupOwner` | user/sp/group | group | targetIsAssignableToRole |
| 16 | `deviceOwner` | user | device | targetDeviceId |
| 17a | `caPolicy*` (5 types) | policy | various | requiresMfa, policyState |
| 17b | `rolePolicyAssignment` | policy | directoryRole | requiresMfaOnActivation |

---

## 9. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Dashboard queries break | High | High | Schema-aware helper function; test before deployment |
| Gremlin queries fail | Low | High | Properties flattened at projection; queries unchanged |
| Delta indexing breaks | Medium | High | POC phase validates with single edge type first |
| DeriveEdges fails to read properties | Medium | Medium | Use `Get-EdgeProperties` helper consistently |
| Data loss during migration | Low | Critical | Backup Cosmos container before backfill |
| Performance regression | Low | Medium | Benchmark document size and RU consumption |
| Dual schema confusion | Medium | Low | Clear `schemaVersion` field; document transition period |

---

## 10. Files Changed Summary

| File | Change Type | Complexity | Risk | Notes |
|------|-------------|------------|------|-------|
| `EntraDataCollection.psm1` | Add 3 functions | Low | Low | `New-EdgeDocument`, `ConvertTo-NestedEdge`, `Get-EdgeProperties` |
| `EntraDataCollection.psd1` | Export functions | Low | Low | Add to `FunctionsToExport` |
| `IndexerConfigs.psd1` | Update schema | Medium | Medium | Add `schemaVersion`, `properties` handling |
| `CollectRelationships/run.ps1` | Refactor 17 phases | High | Medium | ~1800 lines, systematic changes |
| `DeriveEdges/run.ps1` | Update 4 phases | Medium | Medium | Use `Get-EdgeProperties` for reading |
| `DeriveVirtualEdges/run.ps1` | Update output format | Low | Low | Only changes edge creation |
| `ProjectGraphToGremlin/run.ps1` | Schema-aware extraction | Medium | Medium | Handle both v1/v2 schemas |
| `EnrichEdges/run.ps1` | **NEW FILE** | High | Medium | New Azure Function for Epic B |
| `EnrichEdges/function.json` | **NEW FILE** | Low | Low | Cosmos bindings for edges, policies |
| `BackfillNestedSchema/run.ps1` | **NEW FILE** | Low | Low | One-time migration script |
| Dashboard queries | Update property paths | Low | Low | `c.X` → `c.properties.X` |

**Total Scope:** ~10 files, 600-900 lines of changes

---

## 11. Testing Requirements

### 11.1 Unit Tests (Pester)

```powershell
Describe "New-EdgeDocument" {
    It "Creates edge with core fields at root" {
        $edge = New-EdgeDocument `
            -SourceId "user1" -TargetId "group1" `
            -EdgeType "groupMember" -SourceType "user" -TargetType "group" `
            -Timestamp "2026-01-13T10:00:00Z" `
            -Properties @{ membershipType = "Direct" }

        $edge.sourceId | Should -Be "user1"
        $edge.schemaVersion | Should -Be 2
        $edge.properties.membershipType | Should -Be "Direct"
        $edge.PSObject.Properties.Name | Should -Not -Contain "membershipType"
    }

    It "Filters out null and empty values from properties" {
        $edge = New-EdgeDocument `
            -SourceId "user1" -TargetId "group1" `
            -EdgeType "groupMember" -SourceType "user" -TargetType "group" `
            -Timestamp "2026-01-13T10:00:00Z" `
            -Properties @{
                membershipType = "Direct"
                severity = $null
                tier = ""
                inheritancePath = @()
            }

        $edge.properties.Keys | Should -Contain "membershipType"
        $edge.properties.Keys | Should -Not -Contain "severity"
        $edge.properties.Keys | Should -Not -Contain "tier"
        $edge.properties.Keys | Should -Not -Contain "inheritancePath"
    }

    It "Handles IdSuffix for unique edge IDs" {
        $edge = New-EdgeDocument `
            -SourceId "user1" -TargetId "role1" `
            -EdgeType "pimRequest" -SourceType "user" -TargetType "directoryRole" `
            -Timestamp "2026-01-13T10:00:00Z" `
            -IdSuffix "request123" `
            -Properties @{ action = "selfActivate" }

        $edge.id | Should -Be "user1_role1_pimRequest_request123"
    }
}

Describe "Get-EdgeProperties" {
    It "Extracts properties from nested schema (v2)" {
        $edge = [PSCustomObject]@{
            id = "test"; schemaVersion = 2
            properties = @{ membershipType = "Direct"; severity = "High" }
        }

        $props = Get-EdgeProperties -Edge $edge
        $props.membershipType | Should -Be "Direct"
        $props.severity | Should -Be "High"
    }

    It "Extracts properties from flat schema (v1)" {
        $edge = [PSCustomObject]@{
            id = "test"; sourceId = "user1"
            membershipType = "Direct"; severity = "High"
        }

        $props = Get-EdgeProperties -Edge $edge
        $props.membershipType | Should -Be "Direct"
        $props.severity | Should -Be "High"
        $props.Keys | Should -Not -Contain "id"
        $props.Keys | Should -Not -Contain "sourceId"
    }
}

Describe "ConvertTo-NestedEdge" {
    It "Converts flat edge to nested format" {
        $flat = [PSCustomObject]@{
            id = "user1_group1_groupMember"
            objectId = "user1_group1_groupMember"
            edgeType = "groupMember"
            sourceId = "user1"
            targetId = "group1"
            sourceType = "user"
            targetType = "group"
            collectionTimestamp = "2026-01-13T10:00:00Z"
            membershipType = "Direct"
            severity = $null
        }

        $nested = $flat | ConvertTo-NestedEdge

        $nested.schemaVersion | Should -Be 2
        $nested.properties.membershipType | Should -Be "Direct"
        $nested.properties.Keys | Should -Not -Contain "severity"
        $nested.PSObject.Properties.Name | Should -Not -Contain "membershipType"
    }
}
```

### 11.2 Integration Tests

```powershell
Describe "End-to-End Edge Flow" -Tag "Integration" {
    BeforeAll {
        # Requires test tenant connection
        $testTenantId = $env:TEST_TENANT_ID
    }

    It "Collects groupMember edge with nested schema" {
        # Trigger CollectRelationships for a known group
        # Verify edge in Cosmos has schemaVersion = 2
        # Verify properties object contains expected fields
    }

    It "Projects nested edge to Gremlin with flattened properties" {
        # Read edge from Cosmos (nested)
        # Verify edge in Gremlin has flat properties
        # Verify query g.E().has('membershipType', 'Direct') works
    }

    It "DeriveEdges reads nested properties correctly" {
        # Create test appRoleAssignment edge with nested schema
        # Run DeriveEdges
        # Verify derived abuse edge is created with correct properties
    }
}
```

### 11.3 Manual Verification Checklist

- [ ] Deploy to dev environment with `groupMember` only
- [ ] Verify edge document size reduced (Cosmos Data Explorer)
- [ ] Verify Gremlin queries return same results as before
- [ ] Verify Dashboard displays edge data correctly
- [ ] Verify DeriveEdges produces correct abuse edges
- [ ] Run full collection cycle and check for errors
- [ ] Compare RU consumption before/after

---

## 12. EnrichEdges Function Configuration

**File:** `FunctionApp/EnrichEdges/function.json` (NEW)

```json
{
  "bindings": [
    {
      "name": "edgesIn",
      "type": "cosmosDBTrigger",
      "direction": "in",
      "connectionStringSetting": "CosmosDBConnection",
      "databaseName": "EntraRisk",
      "collectionName": "edges",
      "leaseCollectionName": "leases-enrich",
      "createLeaseCollectionIfNotExists": true,
      "feedPollDelay": 5000,
      "startFromBeginning": false
    },
    {
      "name": "policiesIn",
      "type": "cosmosDB",
      "direction": "in",
      "connectionStringSetting": "CosmosDBConnection",
      "databaseName": "EntraRisk",
      "collectionName": "policies",
      "sqlQuery": "SELECT * FROM c WHERE c.policyType = 'conditionalAccess' AND c.state = 'enabled'"
    },
    {
      "name": "edgesOut",
      "type": "cosmosDB",
      "direction": "out",
      "connectionStringSetting": "CosmosDBConnection",
      "databaseName": "EntraRisk",
      "collectionName": "edges"
    }
  ]
}
```

---

## 13. Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-13 | Split into Epic A (Schema) and Epic B (Enrichment) | Separation of concerns, reduces risk |
| 2026-01-13 | Core + Properties nested model | Industry standard |
| 2026-01-13 | POC with single edge type first | Validates approach |
| 2026-01-13 | Use `mfaProtected` not `requiresMfa` for enrichment | Clearer semantics |
| 2026-01-13 | Flatten properties at Gremlin projection | Maintains query compatibility |
| 2026-01-13 | 17 phases (not 14) | Accurate count from code review |

---

## 14. Implementation Order

**Recommended sequence for the implementing developer:**

> **Note:** The labels below indicate implementation order and logical groupings, not strict timelines. Adjust pacing based on your familiarity with the codebase and testing requirements.

### 1: Foundation
1. Add helper functions to `EntraDataCollection.psm1` (Section 4.2)
2. Export functions in `EntraDataCollection.psd1` (Section 4.7)
3. Write and run unit tests (Section 11.1)

### 2: POC
4. Update `IndexerConfigs.psd1` (Section 4.3)
5. Update `CollectRelationships/run.ps1` **Phase 1 only** (`groupMember`)
6. Update `ProjectGraphToGremlin/run.ps1` for dual-schema support
7. Deploy to dev, run manual verification checklist (Section 11.3)

### 3-4: Full Rollout
8. Update remaining 16 phases in `CollectRelationships/run.ps1` (Section 4.4)
9. Update `DeriveEdges/run.ps1` (Section 4.5)
10. Update `DeriveVirtualEdges/run.ps1` (Section 4.6)
11. Run integration tests (Section 11.2)

### 5: Migration
12. Create and run `BackfillNestedSchema/run.ps1` (Section 7.2)
13. Update Dashboard queries (Section 6)
14. Monitor for errors, validate performance

### Future (Epic B)
15. Implement `EnrichEdges/run.ps1` and `function.json` (Sections 5.4, 12)

---

## 15. Handover Checklist

- [ ] Developer has access to dev tenant
- [ ] Developer has Cosmos DB connection string
- [ ] Developer understands current flat schema (read existing edges)
- [ ] Developer can run Pester tests locally
- [ ] Developer has reviewed DangerousPermissions.psd1 for context
- [ ] Questions clarified before starting implementation

---

## Glossary

| Term | Definition |
|------|------------|
| **Core Fields** | Fields at root level of edge document (id, sourceId, targetId, etc.) |
| **Properties** | Nested object containing all non-core, non-null edge metadata |
| **Schema Version** | Integer field indicating document structure (1=flat, 2=nested) |
| **Enrichment** | Process of adding derived security metadata to edges |
| **Physical Edge** | Edge representing a direct relationship from Graph/ARM API |
| **Derived Edge** | Edge created by DeriveEdges representing attack capability |
| **mfaProtected** | Indicates edge target is protected by MFA via CA policy |
