# User Questions
1) What would the risk be if we allowed the function app to access "Script fetches from GitHub: https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/.../permissions.json" so we wouldnt need to manually update the script?

2) After we implement the following, test, and make sure it works... can we integrate it more into the solution? Or should it remain seperate from "DangerousPermissions.psd1"?


# MSGraphPermissions Integration Plan

> **Version:** 1.0
> **Date:** 2026-01-09
> **Status:** Planning
> **Branch:** Version-3.5

---

## Source Project & Licensing

**Source Repository:** https://github.com/Mynster9361/MSGraphPermissions

**Ownership:** The EntraAndAzureRisk project maintainer is a **co-developer** of the MSGraphPermissions project. Full permission is granted to:

- Copy, adapt, and integrate any code from MSGraphPermissions
- Modify algorithms and data structures as needed
- Use without attribution requirements
- Relicense integrated code under EntraAndAzureRisk's license

**No attribution, license headers, or credit comments are required** when integrating code from MSGraphPermissions into this codebase. Treat MSGraphPermissions code as if it were written directly for this project.

**Important:** Do NOT reference or mention the MSGraphPermissions GitHub project anywhere in the codebase (code comments, documentation, commit messages, etc.). The integration should appear as native functionality built directly into EntraAndAzureRisk.

---

## Executive Summary

This plan integrates full Microsoft Graph permission intelligence into the EntraAndAzureRisk platform, expanding analysis from a static list of 14 known-dangerous permissions to a comprehensive, continuously updatable catalog of ~500 Graph permissions mapped to their actual API endpoints.

The integration introduces a new permission analysis layer that enables least-privilege evaluation, over-privileged application detection, and endpoint-level impact analysis without replacing existing dangerous-permission logic. Current red-flag detection is preserved and augmented with contextual right-sizing intelligence.

At a technical level, the solution ingests Microsoft’s official Graph DevX permissions dataset, normalizes it into an indexed PowerShell data file, and exposes fast lookup functions for permission metadata, endpoint coverage, and least-privilege recommendations. This data is incorporated into existing collection, derivation, and dashboard pipelines with minimal architectural disruption.

Operationally, the platform gains the ability to:

Identify applications that request broad Graph permissions but use only narrow functionality

Distinguish “dangerous” permissions from merely “excessive” ones

Quantify blast radius if an app credential is compromised

Produce audit-ready reports on permission hygiene and consent sprawl

The change introduces new graph edge types (appHasDangerousPermission, appHasHighPrivilegePermission) and enriches application resources with detailed permission telemetry, enabling historical tracking and trend analysis consistent with the existing data model.

Implementation is incremental, reversible, and low risk. Core runtime behavior is unaffected unless the new analysis paths are enabled. Rollback requires only removal of the new derivation and dashboard phases.

This integration materially reduces Graph API attack surface visibility gaps and establishes a foundation for future automated least-privilege recommendations based on real API usage.

---

## Value Proposition

### Current State

The existing `DangerousPermissions.psd1` maps **14 known dangerous permissions** to abuse capabilities:

| Permission | Abuse Edge | Severity |
|------------|-----------|----------|
| Application.ReadWrite.All | canAddSecretToAnyApp | Critical |
| AppRoleAssignment.ReadWrite.All | canGrantAnyPermission | Critical |
| RoleManagement.ReadWrite.Directory | canAssignAnyRole | Critical |
| Directory.ReadWrite.All | canModifyDirectory | Critical |
| ... | ... | ... |

**Limitation:** Only answers "Is this permission dangerous?" - cannot recommend alternatives or detect overprivileged apps.

### With Integration

| Capability | Current | After Integration |
|------------|---------|-------------------|
| Dangerous permission detection | 14 hardcoded | 14 + automated updates |
| Least privilege recommendations | No | Yes |
| Overprivileged app detection | No | Yes |
| Permission-to-endpoint mapping | No | Yes |
| Complete permission catalog | No | ~500 permissions |
| Delegated vs Application analysis | Partial | Full |

### Business Value

1. **Shadow IT Detection**: Find apps that requested broad permissions but only use basic endpoints
2. **Attack Surface Reduction**: Identify apps that could use narrower permissions
3. **Consent Fatigue Mitigation**: Warn admins about excessive permission requests
4. **Compliance Reporting**: Permission hygiene reports for audits
5. **Credential Theft Impact Analysis**: Map stolen credentials to accessible endpoints

---

## Architecture

### Deployment Model: Offline Generation

The permission data is generated **offline** (on a developer machine) and committed to the repository. The Azure Function App **never fetches external data at runtime**.

```
┌─────────────────────────────────────────────────────────────────────┐
│ OFFLINE: Developer Machine (has internet access)                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Developer runs: Scripts/Update-GraphApiPermissions.ps1          │
│           │                                                         │
│           ▼                                                         │
│  2. Script fetches from GitHub:                                     │
│     https://raw.githubusercontent.com/microsoftgraph/               │
│     microsoft-graph-devx-content/.../permissions.json               │
│           │                                                         │
│           ▼                                                         │
│  3. Script generates: GraphApiPermissions.psd1                      │
│           │                                                         │
│           ▼                                                         │
│  4. Developer commits to repo                                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ RUNTIME: Azure Function App (no external network required)         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  GraphApiPermissions.psd1 is deployed with the Function App        │
│  and loaded from disk at runtime.                                   │
│                                                                     │
│  No GitHub access required. No firewall rules needed.               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Why Offline Generation?**

| Consideration | Offline (Chosen) | Runtime Fetch |
|---------------|------------------|---------------|
| Network dependencies | None at runtime | Requires outbound to GitHub |
| Firewall rules | No changes needed | Must allow raw.githubusercontent.com |
| Deterministic behavior | Yes - same data every run | No - data could change mid-collection |
| Failure modes | None (file always present) | Fetch failures need fallback logic |
| Freshness | Manual refresh (~monthly) | Always current |

**Refresh Cadence:** Microsoft updates permissions.json approximately weekly. For most use cases, monthly manual refreshes are sufficient. Run `Update-GraphApiPermissions.ps1` when:
- New Graph API endpoints are released that you want to analyze
- Permission definitions change (rare)
- Before major audits or compliance reviews

---

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 1: Permission Data Generation (Manual/Scheduled)              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Microsoft Graph DevX Content Repo                                  │
│  (permissions.json)                                                 │
│           │                                                         │
│           ▼                                                         │
│  Scripts/Update-GraphApiPermissions.ps1                             │
│           │                                                         │
│           ▼                                                         │
│  GraphApiPermissions.psd1                                           │
│  (Indexed by endpoint path)                                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 2: Collection (Every 15 minutes)                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  CollectAppRegistrations/run.ps1                                    │
│           │                                                         │
│           ▼                                                         │
│  Enhanced requiredResourceAccess collection                         │
│  + graphApplicationPermissions                                      │
│  + graphDelegatedPermissions                                        │
│  + permissionAnalysis { excessive, dangerous, recommended }         │
│           │                                                         │
│           ▼                                                         │
│  resources.jsonl (applications with permission details)             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 3: Derivation                                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  DeriveEdges/run.ps1                                                │
│  (New Phase 5: Permission Analysis)                                 │
│           │                                                         │
│           ▼                                                         │
│  Cross-reference granted permissions vs. least privilege            │
│           │                                                         │
│           ▼                                                         │
│  edges.jsonl                                                        │
│  + appHasExcessivePermission                                        │
│  + appHasDangerousPermission                                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 4: Dashboard                                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Dashboard/run.ps1                                                  │
│  (New Permission Analysis Section)                                  │
│           │                                                         │
│           ▼                                                         │
│  Permission Distribution Table                                      │
│  Overprivileged Apps Table                                          │
│  Dangerous Permissions Table                                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Integration with Existing Architecture

The integration adds a new data layer that **complements** (not replaces) `DangerousPermissions.psd1`:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Permission Analysis Layer                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────────────┐    ┌─────────────────────────────────┐  │
│  │ DangerousPermissions  │    │ GraphApiPermissions.psd1        │  │
│  │ .psd1                 │    │                                 │  │
│  │                       │    │                                 │  │
│  │ Purpose: Red Flag     │    │ Purpose: Right-Sizing           │  │
│  │                       │    │                                 │  │
│  │ "Is this dangerous?"  │    │ "What's the minimum needed?"    │  │
│  │                       │    │                                 │  │
│  │ 14 permissions        │    │ ~500 permissions                │  │
│  │ + 30 directory roles  │    │ + endpoint mappings             │  │
│  │ + Azure RBAC          │    │ + least privilege data          │  │
│  │                       │    │                                 │  │
│  └───────────────────────┘    └─────────────────────────────────┘  │
│           │                              │                          │
│           └──────────┬───────────────────┘                          │
│                      ▼                                              │
│              DeriveEdges/run.ps1                                    │
│              (Uses both for comprehensive analysis)                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Permission Data & Core Functions

#### 1.1 Create Update-GraphApiPermissions.ps1

**Purpose:** Download and parse Microsoft's permissions.json into PowerShell data format.

**Location:** `Scripts/Update-GraphApiPermissions.ps1`

**Key Logic:**
```powershell
# Download from Microsoft's Graph DevX Content repo
$PermissionsUrl = "https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/refs/heads/master/permissions/new/permissions.json"

# Parse the JSON structure
# Each permission has:
# - id: GUID
# - displayName: Human-readable name
# - description: What it does
# - isAdmin: Requires admin consent
# - pathSets: Array of { schemeKeys, methods, paths }

# Build indexed structure:
# Path -> Method -> Scheme -> Permissions + LeastPrivilege
```

**Output:** `GraphApiPermissions.psd1`

---

#### 1.2 Create GraphApiPermissions.psd1

**Purpose:** Store permission data indexed for fast lookups during collection and analysis.

**Location:** `FunctionApp/Modules/EntraDataCollection/GraphApiPermissions.psd1`

**Structure:**
```powershell
@{
    # Metadata
    LastUpdated = '2026-01-09T00:00:00Z'
    SourceUrl = 'https://raw.githubusercontent.com/microsoftgraph/...'
    TotalPermissions = 523
    TotalEndpoints = 6842

    # Permission metadata indexed by name
    Permissions = @{
        'User.Read.All' = @{
            Id = 'df021288-bdef-4463-88db-98f22de89214'
            DisplayName = 'Read all users full profiles'
            Description = 'Allows the app to read...'
            IsAdmin = $true
        }
        'User.Read' = @{ ... }
        # ... ~500 more
    }

    # Endpoint index - path -> method -> scheme -> permissions
    Endpoints = @{
        '/users' = @{
            GET = @{
                Application = @('User.Read.All', 'User.ReadWrite.All', 'Directory.Read.All')
                DelegatedWork = @('User.Read', 'User.ReadBasic.All', 'User.Read.All')
                DelegatedPersonal = @('User.Read')
                LeastPrivilege = @{
                    Application = 'User.Read.All'
                    DelegatedWork = 'User.Read'
                    DelegatedPersonal = 'User.Read'
                }
            }
            POST = @{ ... }
        }
        '/users/{id}' = @{ ... }
        '/groups' = @{ ... }
        # ... ~2000 endpoints (limited for file size)
    }

    # Reverse lookup - permission -> endpoints
    PermissionEndpoints = @{
        'User.Read.All' = @('/users', '/users/{id}', '/users/{id}/manager', ...)
        'Mail.Read' = @('/me/messages', '/users/{id}/messages', ...)
        # ...
    }

    # Well-known resource IDs
    WellKnownResourceIds = @{
        MicrosoftGraph = '00000003-0000-0000-c000-000000000000'
        AzureADGraph = '00000002-0000-0000-c000-000000000000'
        Office365Management = 'c5393580-f805-4401-95e8-94b7a6ef2fc2'
    }

    # High-privilege permissions (quick reference)
    HighPrivilegePermissions = @(
        'Application.ReadWrite.All'
        'AppRoleAssignment.ReadWrite.All'
        'Directory.ReadWrite.All'
        'RoleManagement.ReadWrite.Directory'
        # ... others
    )
}
```

---

#### 1.3 Add Functions to EntraDataCollection.psm1

**Location:** `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1`

**Functions to Add:**

```powershell
# Script-level cache
$script:GraphApiPermissionsCache = $null

function Initialize-PermissionCache {
    <#
    .SYNOPSIS
        Loads GraphApiPermissions.psd1 into memory cache.
    #>
    if ($null -eq $script:GraphApiPermissionsCache) {
        $psdPath = Join-Path $PSScriptRoot "GraphApiPermissions.psd1"
        if (Test-Path $psdPath) {
            $script:GraphApiPermissionsCache = Import-PowerShellDataFile $psdPath
            Write-Host "Loaded GraphApiPermissions cache: $($script:GraphApiPermissionsCache.TotalPermissions) permissions, $($script:GraphApiPermissionsCache.TotalEndpoints) endpoints"
        } else {
            Write-Warning "GraphApiPermissions.psd1 not found at $psdPath"
            $script:GraphApiPermissionsCache = @{ Permissions = @{}; Endpoints = @{}; PermissionEndpoints = @{} }
        }
    }
    return $script:GraphApiPermissionsCache
}

function Get-LeastPrivilegePermission {
    <#
    .SYNOPSIS
        Returns the least privileged permission for a Graph API endpoint.
    .PARAMETER Path
        API endpoint path (e.g., "/users/{id}/messages")
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE)
    .PARAMETER Scheme
        Authentication scheme (Application, DelegatedWork, DelegatedPersonal)
    .EXAMPLE
        Get-LeastPrivilegePermission -Path "/users" -Method "GET" -Scheme "Application"
        # Returns: User.Read.All
    #>
    param(
        [string]$Path,
        [string]$Method = "GET",
        [string]$Scheme = "Application"
    )

    $cache = Initialize-PermissionCache
    $normalizedPath = $Path.ToLower().Trim()

    if ($cache.Endpoints.ContainsKey($normalizedPath)) {
        $endpoint = $cache.Endpoints[$normalizedPath]
        if ($endpoint.ContainsKey($Method)) {
            return $endpoint[$Method].LeastPrivilege[$Scheme]
        }
    }

    return $null
}

function Get-AllEndpointPermissions {
    <#
    .SYNOPSIS
        Returns all permissions that grant access to an endpoint.
    #>
    param(
        [string]$Path,
        [string]$Method = "GET"
    )

    $cache = Initialize-PermissionCache
    $normalizedPath = $Path.ToLower().Trim()

    if ($cache.Endpoints.ContainsKey($normalizedPath) -and
        $cache.Endpoints[$normalizedPath].ContainsKey($Method)) {
        return $cache.Endpoints[$normalizedPath][$Method]
    }

    return @{ Application = @(); DelegatedWork = @(); DelegatedPersonal = @() }
}

function Get-EndpointsByPermission {
    <#
    .SYNOPSIS
        Returns all endpoints accessible with a given permission.
    #>
    param(
        [string]$Permission
    )

    $cache = Initialize-PermissionCache

    if ($cache.PermissionEndpoints.ContainsKey($Permission)) {
        return $cache.PermissionEndpoints[$Permission]
    }

    return @()
}

function Get-PermissionMetadata {
    <#
    .SYNOPSIS
        Returns metadata for a permission (ID, display name, admin consent required).
    #>
    param(
        [string]$Permission
    )

    $cache = Initialize-PermissionCache

    if ($cache.Permissions.ContainsKey($Permission)) {
        return $cache.Permissions[$Permission]
    }

    return $null
}

function Test-PermissionIsHighPrivilege {
    <#
    .SYNOPSIS
        Checks if a permission is in the high-privilege list.
    #>
    param(
        [string]$Permission
    )

    $cache = Initialize-PermissionCache
    return $Permission -in $cache.HighPrivilegePermissions
}
```

---

### Phase 2: Enhanced App Registration Collection

#### 2.1 Update CollectAppRegistrations/run.ps1

**Changes:**

1. **Enhanced requiredResourceAccess parsing:**
```powershell
# Initialize permission cache
Initialize-PermissionCache

foreach ($app in $applications) {
    # Existing collection code...

    # Enhanced permission analysis
    $graphAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
    $graphPermissions = $app.requiredResourceAccess | Where-Object { $_.resourceAppId -eq $graphAppId }

    $graphApplicationPermissions = @()
    $graphDelegatedPermissions = @()

    foreach ($access in $graphPermissions.resourceAccess) {
        # Look up permission name from GUID
        $permName = Get-PermissionNameFromId -Id $access.id

        if ($access.type -eq "Role") {
            $graphApplicationPermissions += $permName
        } else {
            $graphDelegatedPermissions += $permName
        }
    }

    # Analysis fields
    $hasDangerousPermissions = $graphApplicationPermissions | Where-Object {
        $_ -in $dangerousPermissionsList
    }

    $hasHighPrivilegePermissions = $graphApplicationPermissions | Where-Object {
        Test-PermissionIsHighPrivilege $_
    }

    # Add to app object
    $app | Add-Member -NotePropertyName "graphApplicationPermissions" -NotePropertyValue $graphApplicationPermissions
    $app | Add-Member -NotePropertyName "graphDelegatedPermissions" -NotePropertyValue $graphDelegatedPermissions
    $app | Add-Member -NotePropertyName "hasDangerousPermissions" -NotePropertyValue ($hasDangerousPermissions.Count -gt 0)
    $app | Add-Member -NotePropertyName "hasHighPrivilegePermissions" -NotePropertyValue ($hasHighPrivilegePermissions.Count -gt 0)
    $app | Add-Member -NotePropertyName "dangerousPermissionCount" -NotePropertyValue $hasDangerousPermissions.Count
    $app | Add-Member -NotePropertyName "totalPermissionCount" -NotePropertyValue ($graphApplicationPermissions.Count + $graphDelegatedPermissions.Count)
}
```

2. **New fields added to application documents:**

| Field | Type | Description |
|-------|------|-------------|
| graphApplicationPermissions | string[] | App-only permissions (by name) |
| graphDelegatedPermissions | string[] | Delegated permissions (by name) |
| hasDangerousPermissions | bool | Has any permission in DangerousPermissions.psd1 |
| hasHighPrivilegePermissions | bool | Has any permission in HighPrivilegePermissions list |
| dangerousPermissionCount | int | Count of dangerous permissions |
| totalPermissionCount | int | Total permission count |

---

### Phase 3: Permission Analysis in DeriveEdges

#### 3.1 Add Phase 5 to DeriveEdges/run.ps1

**New Phase:** After existing Phase 4 (Azure RBAC Abuse)

```powershell
# ===========================================
# PHASE 5: PERMISSION ANALYSIS
# Detect excessive and dangerous permissions
# ===========================================

Write-Host "Phase 5: Analyzing application permissions..."

# Load permission caches
$dangerousPerms = Import-PowerShellDataFile (Join-Path $modulePath "DangerousPermissions.psd1")
Initialize-PermissionCache

# Query applications with permissions
$appQuery = "SELECT * FROM c WHERE c.resourceType = 'application' AND c.effectiveTo = null"
$applications = Invoke-CosmosDbQuery -Container "resources" -Query $appQuery

foreach ($app in $applications) {
    $appId = $app.objectId
    $appName = $app.displayName

    # Check each granted permission
    foreach ($permName in $app.graphApplicationPermissions) {
        # Check if dangerous (already in DangerousPermissions.psd1)
        $dangerousPerm = $dangerousPerms.GraphPermissions.Values | Where-Object { $_.Name -eq $permName }

        if ($dangerousPerm) {
            # Create dangerous permission edge
            $edge = @{
                id = "$($appId)_$($permName)_appHasDangerousPermission"
                edgeType = "appHasDangerousPermission"
                sourceId = $appId
                sourceType = "application"
                sourceDisplayName = $appName
                targetId = $dangerousPerm.Name
                targetType = "graphPermission"
                permissionName = $permName
                abuseEdge = $dangerousPerm.AbuseEdge
                severity = $dangerousPerm.Severity
                description = $dangerousPerm.Description
                effectiveFrom = $timestamp
                effectiveTo = $null
                collectionTimestamp = $timestamp
            }
            $derivedEdges.Add($edge)
        }

        # Check if high-privilege but not in dangerous list
        elseif (Test-PermissionIsHighPrivilege $permName) {
            $permMeta = Get-PermissionMetadata $permName
            $endpoints = Get-EndpointsByPermission $permName

            $edge = @{
                id = "$($appId)_$($permName)_appHasHighPrivilegePermission"
                edgeType = "appHasHighPrivilegePermission"
                sourceId = $appId
                sourceType = "application"
                sourceDisplayName = $appName
                targetId = $permName
                targetType = "graphPermission"
                permissionName = $permName
                permissionDisplayName = $permMeta.DisplayName
                isAdminConsent = $permMeta.IsAdmin
                endpointCount = $endpoints.Count
                severity = "High"
                effectiveFrom = $timestamp
                effectiveTo = $null
                collectionTimestamp = $timestamp
            }
            $derivedEdges.Add($edge)
        }
    }
}

Write-Host "Phase 5 complete: Generated $($derivedEdges.Count) permission edges"
```

#### 3.2 New Edge Types

| edgeType | Source | Target | Description |
|----------|--------|--------|-------------|
| appHasDangerousPermission | application | graphPermission | App has permission from DangerousPermissions.psd1 |
| appHasHighPrivilegePermission | application | graphPermission | App has high-privilege permission (but not necessarily dangerous) |
| appHasExcessivePermission | application | graphPermission | App has broader permission than needed (future: requires audit log analysis) |

**Edge Properties:**

```json
{
  "id": "{appId}_{permissionName}_{edgeType}",
  "edgeType": "appHasDangerousPermission",
  "sourceId": "app-object-id",
  "sourceType": "application",
  "sourceDisplayName": "My App",
  "targetId": "Application.ReadWrite.All",
  "targetType": "graphPermission",
  "permissionName": "Application.ReadWrite.All",
  "abuseEdge": "canAddSecretToAnyApp",
  "severity": "Critical",
  "description": "Can add credentials to any application registration",
  "effectiveFrom": "2026-01-09T00:00:00Z",
  "effectiveTo": null,
  "collectionTimestamp": "2026-01-09T00:00:00Z"
}
```

---

### Phase 4: Dashboard Integration

#### 4.1 Add Permission Analysis Section to Dashboard/run.ps1

**New Section:** After existing sections (Users, Groups, Service Principals, Azure Resources, Policies, Audit)

```powershell
# ===========================================
# CONTAINER 7: PERMISSION ANALYSIS
# ===========================================

# Query dangerous permission edges
$dangerousPermEdges = $edgesIn | Where-Object { $_.edgeType -eq 'appHasDangerousPermission' -and $_.effectiveTo -eq $null }
$highPrivPermEdges = $edgesIn | Where-Object { $_.edgeType -eq 'appHasHighPrivilegePermission' -and $_.effectiveTo -eq $null }

# Group by permission name for distribution
$permissionDistribution = $dangerousPermEdges + $highPrivPermEdges |
    Group-Object permissionName |
    Sort-Object Count -Descending |
    Select-Object -First 20 |
    ForEach-Object {
        @{
            Permission = $_.Name
            AppCount = $_.Count
            Severity = ($_.Group | Select-Object -First 1).severity
            Apps = ($_.Group | Select-Object -ExpandProperty sourceDisplayName) -join ", "
        }
    }

# Apps with most dangerous permissions
$riskyApps = $dangerousPermEdges |
    Group-Object sourceDisplayName |
    Sort-Object Count -Descending |
    Select-Object -First 20 |
    ForEach-Object {
        @{
            AppName = $_.Name
            DangerousPermissions = $_.Count
            Permissions = ($_.Group | Select-Object -ExpandProperty permissionName) -join ", "
            TopSeverity = ($_.Group | Sort-Object { switch ($_.severity) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } default { 3 } } } | Select-Object -First 1).severity
        }
    }
```

**HTML Output:**

```html
<!-- PERMISSION ANALYSIS TAB -->
<div id="permissionAnalysis" class="tab-content">
    <h2>Permission Analysis</h2>

    <h3>Top 20 Dangerous Permissions by App Count</h3>
    <table>
        <tr><th>Permission</th><th>App Count</th><th>Severity</th></tr>
        <!-- Rows generated dynamically -->
    </table>

    <h3>Apps with Most Dangerous Permissions</h3>
    <table>
        <tr><th>App Name</th><th>Dangerous Permission Count</th><th>Top Severity</th><th>Permissions</th></tr>
        <!-- Rows generated dynamically -->
    </table>

    <h3>High-Privilege Permission Distribution</h3>
    <table>
        <tr><th>Permission</th><th>App Count</th><th>Description</th></tr>
        <!-- Rows generated dynamically -->
    </table>
</div>
```

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `Scripts/Update-GraphApiPermissions.ps1` | CREATE | Script to download and parse Microsoft permissions data |
| `FunctionApp/Modules/EntraDataCollection/GraphApiPermissions.psd1` | CREATE | Permission data indexed by endpoint |
| `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1` | MODIFY | Add 6 permission lookup functions |
| `FunctionApp/CollectAppRegistrations/run.ps1` | MODIFY | Enhanced permission collection with analysis fields |
| `FunctionApp/DeriveEdges/run.ps1` | MODIFY | Add Phase 5 for permission analysis |
| `FunctionApp/Dashboard/run.ps1` | MODIFY | Add Permission Analysis UI section |
| `FunctionApp/Modules/EntraDataCollection/IndexerConfigs.psd1` | MODIFY | Add new fields to compare/document lists |
| `Scripts/Entra Scripts/claude-to-do-reference.md` | MODIFY | Document this integration |

---

## Implementation Order

1. **Create Update-GraphApiPermissions.ps1** - Script to generate permission data
2. **Run Update-GraphApiPermissions.ps1** - Generate initial GraphApiPermissions.psd1
3. **Add functions to EntraDataCollection.psm1** - Permission lookup utilities
4. **Enhance CollectAppRegistrations/run.ps1** - Collect detailed permission data
5. **Add Phase 5 to DeriveEdges/run.ps1** - Generate permission edges
6. **Update IndexerConfigs.psd1** - Add new fields for indexing
7. **Add Permission Analysis section to Dashboard** - Visualize results
8. **Deploy and test** - Full end-to-end verification

---

## Testing Plan

### Unit Tests

1. **Update-GraphApiPermissions.ps1**
   - Verify download succeeds
   - Verify parsing produces valid .psd1
   - Verify file can be loaded with Import-PowerShellDataFile

2. **Permission Lookup Functions**
   - Test Get-LeastPrivilegePermission returns correct values
   - Test Get-EndpointsByPermission returns expected endpoints
   - Test cache initialization works correctly

### Integration Tests

1. **CollectAppRegistrations**
   - Deploy updated collector
   - Run collection
   - Verify blob contains new permission fields

2. **DeriveEdges**
   - Run derivation
   - Verify appHasDangerousPermission edges are created
   - Verify edge properties are correct

3. **Dashboard**
   - Load dashboard
   - Verify Permission Analysis tab appears
   - Verify tables show correct data

---

## Rollback Plan

If issues occur:

1. **Revert CollectAppRegistrations/run.ps1** - Remove permission analysis code
2. **Revert DeriveEdges/run.ps1** - Remove Phase 5
3. **Revert Dashboard/run.ps1** - Remove Permission Analysis section
4. **Keep GraphApiPermissions.psd1** - Reference data doesn't affect runtime

---

## Future Enhancements

### Phase 2: Excessive Permission Detection

Requires audit log integration to detect apps requesting more permissions than they actually use:

```powershell
# Future: Compare granted permissions vs. actual API calls
$grantedEndpoints = Get-EndpointsByPermission $permName
$actualCalls = Get-AuditLogsForApp -AppId $appId

$unusedEndpoints = $grantedEndpoints | Where-Object {
    $_ -notin $actualCalls
}

if ($unusedEndpoints.Count -gt ($grantedEndpoints.Count * 0.8)) {
    # App is only using 20% of granted endpoints - likely excessive
}
```

### Phase 3: Least Privilege Recommendations

Generate actionable recommendations:

```powershell
# Find minimum permission that would cover actual usage
$actualEndpoints = Get-AuditLogsForApp -AppId $appId
$minPermissions = Find-MinimumPermissionSet -Endpoints $actualEndpoints

# Compare to current grants
$excessPermissions = $currentPermissions | Where-Object { $_ -notin $minPermissions }

# Generate recommendation edge
@{
    edgeType = "permissionRecommendation"
    currentPermission = "User.ReadWrite.All"
    recommendedPermission = "User.Read.All"
    reason = "App only performs read operations on /users endpoint"
}
```

---

## Appendix: Data Source Details

### Microsoft Graph DevX Content Repository

**URL:** https://github.com/microsoftgraph/microsoft-graph-devx-content

**Permissions JSON Location:** `/permissions/new/permissions.json`

**Raw URL:** https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/refs/heads/master/permissions/new/permissions.json

**Update Frequency:** Updated by Microsoft as Graph API evolves (approximately weekly)

**Structure:**
```json
{
  "PermissionName": {
    "id": "GUID",
    "displayName": "Human readable name",
    "description": "What it does",
    "isAdmin": true/false,
    "isHidden": true/false,
    "consentType": "Admin"/"User",
    "grantType": "DelegatedWork"/"Application",
    "pathSets": [
      {
        "schemeKeys": ["Application", "DelegatedWork"],
        "methods": ["GET", "POST"],
        "paths": [
          "/users least=DelegatedWork",
          "/users/{id}"
        ]
      }
    ]
  }
}
```

---

## Advanced Algorithms to Implement

### Least-Privilege Algorithm

The following multi-tier heuristic should be implemented for determining least-privilege permissions:

When Microsoft's data doesn't have an explicit `least=` marker, use this 5-tier fallback:

| Tier | Heuristic | Description |
|------|-----------|-------------|
| 1 | Explicit markers | Use `least=` from Microsoft data if present |
| 2 | Single permission | If only 1 permission grants access, it's implicitly least |
| 3 | Read vs ReadWrite | Prefer `X.Read.All` over `X.ReadWrite.All` |
| 4 | Path count | Count endpoints each permission covers; fewest = least broad |
| 5 | Disambiguation | For ties, apply alphabetical or additional rules |

**Example:** If `Mail.Read` and `Mail.ReadWrite` both access `/me/messages` without explicit markers, infer `Mail.Read` is least-privileged.

**Implementation:**
```powershell
function Get-LeastPrivilegePermission {
    # Tier 1: Check explicit least= marker
    # Tier 2: Single permission = implicitly least
    # Tier 3: Read vs ReadWrite pattern → prefer Read
    # Tier 4: Count total paths → fewest wins
    # Tier 5: Disambiguate ties
}
```

---

### AlsoRequires Dependency Tracking

Some permissions require *additional* permissions to work. The `Update-GraphApiPermissions.ps1` script should extract and store this:

```powershell
# Extract from Microsoft's data
AlsoRequires = $claim.AlsoRequires -join ', '
```

**Store in GraphApiPermissions.psd1:**
```powershell
Endpoints = @{
    '/users/{id}/assignLicense' = @{
        POST = @{
            Application = @(
                @{ Permission = 'User.ReadWrite.All'; AlsoRequires = @('Directory.ReadWrite.All') }
            )
        }
    }
}
```

---

### Case-Insensitive Path Lookups

PowerShell hashtables in `.psd1` files are case-sensitive. Queries for `/Users` vs `/users` may fail.

**Use case-insensitive dictionary in module cache:**
```powershell
$script:EndpointCache = [System.Collections.Generic.Dictionary[string,object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
```

---

### Complete Reverse Lookup (No Truncation)

Avoid truncating permission → endpoint mappings. Truncation hides the true blast radius for broad permissions like `Directory.ReadWrite.All`.

If the `Update-GraphApiPermissions.ps1` script limits endpoints (e.g., to 50), remove the limit or document it clearly. Consider lazy-loading for very broad permissions.

---

### Pipeline Support

Add `-ValueFromPipeline` to lookup functions for interactive use:
```powershell
"/users/{id}", "/groups/{id}" | Get-GraphPermissions -Method GET
```

---

### Implementation Priority

| Priority | Enhancement | Effort | Impact |
|----------|-------------|--------|--------|
| **High** | Implement multi-tier least-privilege algorithm | Medium | Better recommendations |
| **High** | Keep GUID indexing | None | Essential for Graph API matching |
| **Medium** | Store `AlsoRequires` dependencies | Low | Complete permission analysis |
| **Medium** | Use case-insensitive dictionary | Low | Robustness |
| **Low** | Remove endpoint truncation limit | Low | Full blast radius visibility |
| **Low** | Add pipeline support | Low | Interactive usability |

---

### Complete Function Implementations

The following functions should be added to `EntraDataCollection.psm1`:

```powershell
function Get-LeastPrivilegePermission {
    <#
    .SYNOPSIS
        Returns the least privileged permission for a Graph API endpoint.
        Uses multi-tier heuristics when no explicit marker exists.
    #>
    param(
        [Parameter(ValueFromPipeline)]
        [string]$Path,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = "GET",
        [ValidateSet('Application', 'DelegatedWork', 'DelegatedPersonal')]
        [string]$Scheme = "Application"
    )

    begin {
        $cache = Initialize-PermissionCache
    }

    process {
        $normalizedPath = $Path.ToLowerInvariant()

        # 1. Check for explicit least= marker
        $endpoint = $cache.Endpoints[$normalizedPath]
        if ($endpoint -and $endpoint[$Method].LeastPrivilege[$Scheme]) {
            return $endpoint[$Method].LeastPrivilege[$Scheme]
        }

        # 2. Get all permissions for this endpoint
        $allPerms = $endpoint[$Method][$Scheme]
        if (-not $allPerms -or $allPerms.Count -eq 0) { return $null }

        # 3. Single permission = implicitly least
        if ($allPerms.Count -eq 1) {
            return $allPerms[0]
        }

        # 4. Read vs ReadWrite pattern
        $readPerms = $allPerms | Where-Object { $_ -match '\.Read\.' -or $_ -match '\.Read$' }
        $writePerms = $allPerms | Where-Object { $_ -match '\.ReadWrite\.' -or $_ -match '\.ReadWrite$' }

        if ($readPerms.Count -gt 0 -and $writePerms.Count -gt 0) {
            # Prefer Read variants
            $allPerms = $readPerms
        }

        # 5. Fewest endpoints = least broad
        $permissionScopes = @{}
        foreach ($perm in $allPerms) {
            $endpoints = $cache.PermissionEndpoints[$perm]
            $permissionScopes[$perm] = if ($endpoints) { $endpoints.Count } else { [int]::MaxValue }
        }

        $leastBroad = $permissionScopes.GetEnumerator() |
            Sort-Object Value |
            Select-Object -First 1

        return $leastBroad.Key
    }
}

function Get-AllEndpointPermissions {
    <#
    .SYNOPSIS
        Returns all permissions that grant access to an endpoint.
        Includes IsLeastPrivileged and AlsoRequires properties.
    #>
    param(
        [Parameter(ValueFromPipeline)]
        [string]$Path,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = "GET",
        [ValidateSet('Application', 'DelegatedWork', 'DelegatedPersonal')]
        [string]$Scheme
    )

    begin {
        $cache = Initialize-PermissionCache
    }

    process {
        $normalizedPath = $Path.ToLowerInvariant()
        $endpoint = $cache.Endpoints[$normalizedPath]

        if (-not $endpoint -or -not $endpoint[$Method]) {
            Write-Warning "Path '$Path' with method '$Method' not found"
            return
        }

        $methodData = $endpoint[$Method]
        $schemesToProcess = if ($Scheme) { @($Scheme) } else { @('Application', 'DelegatedWork', 'DelegatedPersonal') }

        foreach ($s in $schemesToProcess) {
            if (-not $methodData[$s]) { continue }

            $leastPrivPerm = $methodData.LeastPrivilege[$s]

            foreach ($perm in $methodData[$s]) {
                [PSCustomObject]@{
                    Path = $Path
                    Method = $Method
                    Scheme = $s
                    Permission = $perm
                    IsLeastPrivileged = ($perm -eq $leastPrivPerm)
                    AlsoRequires = $cache.PermissionDependencies[$perm] -join ', '
                }
            }
        }
    }
}
```

---

**End of Plan**
