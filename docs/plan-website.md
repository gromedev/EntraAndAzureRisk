# Alpenglow Dashboard - Design Document

**Version**: 1.0
**Last Updated**: 2026-01-12
**Status**: Draft

---

## Table of Contents

1. [Overview](#1-overview)
2. [Data Foundation](#2-data-foundation)
3. [Feature Specifications](#3-feature-specifications)
4. [User Interface Design](#4-user-interface-design)
5. [Technical Architecture](#5-technical-architecture)
6. [Implementation Plan](#6-implementation-plan)
7. [Appendix: Data Availability Audit](#7-appendix-data-availability-audit)

---

## 1. Overview

### 1.1 Purpose

The Alpenglow Dashboard is a security posture visualization and analysis tool that transforms collected Entra ID and Azure data into actionable insights. It serves as the primary interface for security analysts and management to understand identity risks, compliance status, and cost optimization opportunities.

### 1.2 Target Users

| User Type | Needs | Frequency |
|-----------|-------|-----------|
| **Security Analysts** | Detailed data exploration, investigation, attack path analysis | Daily |
| **Security Managers** | Posture overview, trend monitoring, compliance reporting | Weekly |
| **Executives / Leadership** | High-level metrics, cost savings, risk summary | Monthly |

### 1.3 Key Differentiators

What makes this dashboard valuable vs. the Entra/Azure portals:

1. **Unified View**: Entra ID + Azure in one place (portals are separate)
2. **Attack Path Visibility**: Derived abuse edges show "who can compromise what"
3. **Cross-Cloud Analysis**: Entra permissions → Azure resource access
4. **Historical Context**: Trend data over 90 days (portals show current state only)
5. **Cost Insights**: License optimization, orphaned resources

### 1.4 Relationship to Existing Components

| Component | Role | Future |
|-----------|------|--------|
| **Data Collection Function App** | Collects data from Graph/Azure APIs | Stays in Function App 1 |
| **Debug Dashboard** | Developer/troubleshooting view of raw data | Stays in Function App 1, renamed |
| **Alpenglow Dashboard** | Production security dashboard | NEW - Function App 2 |

---

## 2. Data Foundation

### 2.1 What We Collect

| Category | Entity Types | Edge Types | Key Fields |
|----------|--------------|------------|------------|
| **Principals** | Users, Groups, Service Principals, Devices, Admin Units | - | `perUserMfaState`, `lastSignInDateTime`, `riskLevel`, `authMethodCount` |
| **Resources** | Applications, Subscriptions, Resource Groups, Key Vaults, VMs | - | `passwordCredentials`, `keyCredentials`, `apiPermissionCount` |
| **Relationships** | - | 15+ types: `directoryRole`, `pimEligible`, `azureRbac`, `groupMember`, `appOwner`, `keyVaultAccess`, `caPolicyTargets*` | `edgeType`, `assignmentType` |
| **Derived Edges** | - | 50+ abuse types: `isGlobalAdmin`, `canAddSecretToAnyApp`, `canAssignAnyRole` | `severity`, `capability` |
| **Policies** | CA, Auth Methods, PIM, Intune | `caPolicyTargetsPrincipal`, `caPolicyExcludesPrincipal` | `state`, `requiresMfa` |
| **Changes** | Audit records | - | `changeType`, `changeTimestamp`, `delta` |

### 2.2 Data Availability Summary

Based on code audit, here's what we can actually build:

| Status | Count | Examples |
|--------|-------|----------|
| ✅ **Ready Now** | 19 | Tier 0 exposure, MFA status, expiring secrets, CA gaps, device compliance |
| ⚠️ **Needs Query Logic** | 12 | Unused licenses (need JOIN), stale admins (need JOIN), blast radius |
| ❌ **Not Collected** | 10 | Sign-in logs, M365 usage, VM metrics, historical trends |
| 🔧 **Needs Backend** | 5 | Metrics container, compliance frameworks |

**Critical Gap**: Historical trend data requires a new `metrics` container with daily aggregations.

---

## 3. Feature Specifications

### 3.1 MVP Features (Phase 1-2)

Only features with ✅ or ⚠️ data availability.

#### 3.1.1 Security Posture Cards

**Purpose**: At-a-glance risk summary for the landing page

| Card | Metric | Data Source | Status |
|------|--------|-------------|--------|
| **Tenant Takeover Risk** | Count of users who can compromise the tenant | `directoryRole` edges where role is Tier 0 + derived `canAssignAnyRole` edges + ownership chains | ✅ Ready |
| **MFA Gaps** | Privileged users without MFA | Users with admin edges WHERE `perUserMfaState != 'enforced'` | ✅ Ready |
| **Credential Exposure** | Secrets expiring in 30 days | Apps/SPs where `passwordCredentials.endDateTime < now + 30 days` | ✅ Ready |
| **Policy Coverage** | % users covered by MFA CA policy | Count `caPolicyTargetsPrincipal` edges vs total users | ✅ Ready |
| **Cost Opportunity** | $ in unused licenses | Users with `assignedLicenseSkus` WHERE `lastSignInDateTime > 90 days` | ⚠️ Need JOIN |

**Implementation**: Query edges container at page load, aggregate counts, display as cards.

#### 3.1.2 Privileged Access View

**Purpose**: Who has admin access and how

| Element | Description | Data Source |
|---------|-------------|-------------|
| **Tier 0 Admins Table** | Global Admins, Privileged Role Admins, App Admins | `directoryRole` edges filtered by dangerous role GUIDs |
| **PIM vs Permanent Chart** | Pie chart showing assignment types | Count `directoryRole` vs `pimEligible` edges |
| **Shadow Admins Table** | Users who own apps/groups with admin roles | `appOwner` + `spOwner` + `groupOwner` edges → filter targets with admin roles |
| **Stale Admins** | Admins with no sign-in > 30 days | Admin edges + JOIN on principals for `lastSignInDateTime` |

#### 3.1.3 Credential Risk View

**Purpose**: Expiring secrets and dangerous permissions

| Element | Description | Data Source |
|---------|-------------|-------------|
| **Expiring Secrets Table** | Apps/SPs with secrets expiring soon | Resources WHERE `expiringSecretsCount > 0` |
| **Dangerous Permissions Table** | Apps with high-risk Graph permissions | Derived edges: `canAddSecretToAnyApp`, `canGrantAnyPermission`, etc. |
| **Over-Permissioned Apps** | Apps with > 10 Graph permissions | Resources WHERE `apiPermissionCount > 10` |

#### 3.1.4 Compliance View

**Purpose**: Policy coverage and gaps

| Element | Description | Data Source |
|---------|-------------|-------------|
| **MFA Coverage Gauge** | % of users with MFA enabled | Count principals WHERE `perUserMfaState IN ('enabled', 'enforced')` / total users |
| **CA Policy Gaps Table** | Users excluded from key policies | `caPolicyExcludesPrincipal` edges filtered by policies with `requiresMfa = true` |
| **Device Compliance** | % of devices compliant | Count devices WHERE `isCompliant = true` / total devices |
| **PIM Adoption %** | Ratio of eligible to permanent roles | `pimEligible` count / (`directoryRole` + `pimEligible`) count |

#### 3.1.5 Cost & Cleanup View

**Purpose**: License optimization and orphaned resources

| Element | Description | Data Source |
|---------|-------------|-------------|
| **Unused Licenses Table** | Users with licenses but no recent sign-in | Principals with `assignedLicenseSkus` + `lastSignInDateTime > 90 days ago` |
| **Orphaned Groups** | Groups with no members | Principals (groups) WHERE `memberCountTotal = 0` |
| **Guest Access Review** | External users with privileged access | Principals WHERE `userType = 'Guest'` + have admin or ownership edges |
| **External Apps Table** | Third-party apps with consent grants | `oauth2PermissionGrant` edges |

#### 3.1.6 Data Browser (Enhanced Debug Dashboard)

**Purpose**: Raw data exploration for analysts

| Element | Description |
|---------|-------------|
| **Principals Tab** | Users, Groups, SPs, Devices, Admin Units - sortable tables with filters |
| **Resources Tab** | Applications, Azure resources, Role definitions |
| **Edges Tab** | All relationship types with filtering by edge type |
| **Policies Tab** | CA, Auth Methods, PIM policies, Intune |
| **Audit Tab** | Recent changes with filtering by entity type |

**Enhancement over current debug dashboard**: Add column filters, CSV export, search.

### 3.2 Future Features (Phase 3+)

Features that need additional work before implementation.

| Feature | Blocker | Notes |
|---------|---------|-------|
| **Historical Trend Charts** | Need `metrics` container | Requires backend: daily metric aggregation |
| **Attack Path Visualization** | Need graph traversal logic | Currently just tables; graphical paths need Gremlin or custom |
| **Blast Radius Calculator** | Need query logic | Data exists, need UI for "select user → show impact" |
| **Sign-in Analysis** | Not collected | Would need `/auditLogs/signIns` API |
| **Compliance Frameworks** | Need mapping design | SOC 2, NIST, ISO 27001 control mapping |

---

## 4. User Interface Design

### 4.1 Layout Structure

```
┌─────────────────────────────────────────────────────────────────┐
│ HEADER: Tenant Name | Data Age: "6 hours ago" | Refresh | User  │
├──────────────┬──────────────────────────────────────────────────┤
│              │                                                   │
│  NAVIGATION  │  CONTENT AREA                                    │
│              │                                                   │
│  Dashboard   │  [Depends on selected section]                   │
│  Privileged  │                                                   │
│  Credentials │                                                   │
│  Compliance  │                                                   │
│  Cost        │                                                   │
│  Data        │                                                   │
│              │                                                   │
├──────────────┴──────────────────────────────────────────────────┤
│ FOOTER: Last collection: Jan 10 2:14 AM | Duration: 14m        │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Navigation

| Section | Icon | Description |
|---------|------|-------------|
| **Dashboard** | 📊 | Landing page with posture cards |
| **Privileged Access** | 🔑 | Admin roles, PIM, shadow admins |
| **Credentials** | 🔐 | Expiring secrets, dangerous permissions |
| **Compliance** | ✓ | MFA coverage, CA gaps, device compliance |
| **Cost & Cleanup** | 💰 | License optimization, orphaned resources |
| **Data Browser** | 📁 | Raw data tables (enhanced debug) |

### 4.3 Landing Page (Dashboard)

```
┌─────────────────────────────────────────────────────────────────┐
│ SECURITY POSTURE SUMMARY                                        │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
│   TENANT    │    MFA      │ CREDENTIALS │   POLICY    │  COST   │
│  TAKEOVER   │    GAPS     │  EXPOSURE   │  COVERAGE   │ SAVINGS │
│             │             │             │             │         │
│     8       │     12      │     23      │    78%      │ $4,200  │
│   users     │  privileged │   secrets   │  protected  │ /month  │
│             │ without MFA │  expiring   │             │         │
│  [Details]  │  [Details]  │  [Details]  │  [Details]  │[Details]│
└─────────────┴─────────────┴─────────────┴─────────────┴─────────┘

┌─────────────────────────────────────────────────────────────────┐
│ RECENT CHANGES                                                  │
├─────────────────────────────────────────────────────────────────┤
│ • New Global Admin added: john.doe@contoso.com (2 hours ago)    │
│ • CA Policy modified: "Block Legacy Auth" (5 hours ago)         │
│ • App secret expiring: HR-Application (expires in 7 days)       │
│ [View All Changes →]                                            │
└─────────────────────────────────────────────────────────────────┘
```

### 4.4 Data Tables

All data tables follow this pattern:

```
┌─────────────────────────────────────────────────────────────────┐
│ USERS (2,847)                                    [Export CSV]   │
├─────────────────────────────────────────────────────────────────┤
│ Filter: [___________] [MFA: Any ▼] [Risk: Any ▼] [Clear]       │
├──────────────┬──────────────────────┬─────────┬────────┬────────┤
│ Display Name │ UPN                  │ MFA     │ Risk   │ Sign-In│
│ ▲            │                      │         │        │        │
├──────────────┼──────────────────────┼─────────┼────────┼────────┤
│ John Doe     │ john.doe@contoso.com │ ✓ Phone │ None   │ 2h ago │
│ Jane Smith   │ jane.smith@contoso   │ ✗ None  │ 🔴 High│ 1d ago │
├──────────────┴──────────────────────┴─────────┴────────┴────────┤
│ [← Prev] Page 1 of 57 [Next →]              Showing 1-50 of 2847│
└─────────────────────────────────────────────────────────────────┘
```

### 4.5 Visual Design

| Element | Specification |
|---------|---------------|
| **Font** | Segoe UI (Windows native) |
| **Primary Color** | #2c3e50 (dark blue-gray) |
| **Accent** | #3498db (blue) |
| **Success** | #27ae60 (green) |
| **Warning** | #f39c12 (orange) |
| **Error** | #e74c3c (red) |
| **Background** | #ecf0f1 (light gray) |

---

## 5. Technical Architecture

### 5.1 Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Function App 1: Data Collection                                 │
│ (14 Graph API permissions - HIGH privilege)                     │
│                                                                 │
│ • Orchestrator, Collectors, Indexers, DeriveEdges              │
│ • Debug Dashboard (HTTP endpoint)                               │
│ • Timer trigger: every 6 hours                                  │
└───────────────────────────────┬─────────────────────────────────┘
                                │ writes to
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ Cosmos DB                                                       │
│ • principals, resources, edges, policies, events, audit        │
│ • metrics (NEW - for historical trends)                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │ reads from
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ Function App 2: Alpenglow Dashboard                             │
│ (Read-only Cosmos access - LOW privilege)                       │
│                                                                 │
│ • HTTP endpoint serving HTML                                    │
│ • Azure AD Easy Auth                                            │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Tech Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| **Runtime** | Azure Functions (PowerShell) | Consistent with data collection |
| **Data Access** | Cosmos DB input bindings | Proven pattern, no new infrastructure |
| **Frontend** | Server-rendered HTML + vanilla JS | Simple, no build step |
| **Charts** | Chart.js (CDN) | Lightweight, no dependencies |
| **Auth** | Azure AD Easy Auth | Built-in, zero code |

### 5.3 Data Flow

1. User navigates to Alpenglow Dashboard URL
2. Azure AD Easy Auth validates user token
3. Function App reads from Cosmos DB via input bindings
4. PowerShell generates HTML with embedded data
5. JavaScript provides interactivity (sorting, filtering, charts)

### 5.4 Queries Needed

| Feature | Query Pattern |
|---------|---------------|
| **Tier 0 Count** | `edges WHERE edgeType = 'directoryRole' AND targetRoleDefinitionName IN ('Global Administrator', ...)` |
| **MFA-less Admins** | Above JOIN `principals WHERE perUserMfaState != 'enforced'` |
| **Expiring Secrets** | `resources WHERE entityType = 'application' AND expiringSecretsCount > 0` |
| **CA Exclusions** | `edges WHERE edgeType = 'caPolicyExcludesPrincipal' AND requiresMfa = true` |
| **Unused Licenses** | `principals WHERE assignedLicenseSkus != null AND lastSignInDateTime < (now - 90 days)` |

---

## 6. Implementation Plan

### 6.1 Phase 1: Debug Dashboard Enhancements (Week 1-2)

**Goal**: Quick wins on existing dashboard while preparing backend for trends.

| Task | Type | Effort |
|------|------|--------|
| Rename to "Debug Dashboard" in UI | Frontend | 1 hour |
| Add Security Posture Summary section (5 cards) | Frontend | 1 day |
| Add per-column filter inputs to all tables | Frontend | 1 day |
| Add CSV export buttons | Frontend | 0.5 day |
| Design metrics schema | Backend | 0.5 day |
| Create `metrics` container in Cosmos DB | Backend | 0.5 day |
| Add `CollectMetrics` function to Orchestrator | Backend | 1 day |
| Implement 90-day TTL | Backend | 0.5 day |

### 6.2 Phase 2: Alpenglow Dashboard MVP (Week 3-5)

**Goal**: Separate, polished dashboard for analysts and managers.

| Task | Type | Effort |
|------|------|--------|
| Create Function App 2 infrastructure (Bicep) | Infra | 1 day |
| Configure Managed Identity (read-only Cosmos) | Infra | 0.5 day |
| Configure Azure AD Easy Auth | Infra | 0.5 day |
| Build landing page with 5 posture cards | Frontend | 1 day |
| Build Privileged Access view | Frontend | 1 day |
| Build Credentials view | Frontend | 1 day |
| Build Compliance view | Frontend | 1 day |
| Build Cost & Cleanup view | Frontend | 1 day |
| Build Data Browser (enhanced tables) | Frontend | 2 days |
| Add historical trend charts (from metrics) | Frontend | 1 day |
| Testing and refinement | QA | 2 days |

### 6.3 Phase 3: Advanced Features (V4+)

| Task | Dependency | Notes |
|------|------------|-------|
| Attack path visualization | Gremlin integration | After Function App 3 |
| Blast radius calculator | Query logic | Complex traversal |
| Sign-in analysis | New API collection | `/auditLogs/signIns` |
| Compliance framework mapping | Design work | SOC 2, NIST, ISO |

---

## 7. Appendix: Data Availability Audit

### Legend
- ✅ **YES** - Data collected and working
- ⚠️ **PARTIAL** - Data exists but needs JOIN/calculation
- ❌ **NO** - Not currently collected
- 🔧 **NEEDS BACKEND** - Requires new collection or container

### Security Risk Insights

| Insight | Status | Notes |
|---------|--------|-------|
| Tier 0 Exposure | ✅ | `directoryRole` edges + derived abuse edges |
| MFA-less Admins | ✅ | `perUserMfaState` field on users |
| Shortest Path to Admin | ⚠️ | Edges exist, need traversal logic |
| Shadow Admins (ownership) | ✅ | Ownership edges + derived `canAddSecret*` |
| Entra → Azure Escalation | ⚠️ | Have both edge types, need JOIN |
| VM Code Execution Paths | ✅ | `azureRbac` edges with VM Contributor |
| Key Vault Exposure | ✅ | `keyVaultAccess` edges |
| Expiring Secrets | ✅ | `passwordCredentials.endDateTime` |
| Dangerous Permissions | ✅ | Derived edges from DangerousPermissions.psd1 |

### Compliance & Governance

| Insight | Status | Notes |
|---------|--------|-------|
| MFA Coverage % | ✅ | `perUserMfaState` + `authMethodCount` |
| CA Policy Gaps | ✅ | `caPolicyExcludesPrincipal` edges |
| PIM Adoption | ✅ | `directoryRole` vs `pimEligible` counts |
| Device Compliance | ✅ | `isCompliant` field on devices |
| Admin Sprawl (trend) | ❌ | Requires metrics container |
| Stale Privileged Accounts | ⚠️ | Admin edges + `lastSignInDateTime` JOIN |

### Business Value

| Insight | Status | Notes |
|---------|--------|-------|
| Unused Licenses | ⚠️ | Have data, need JOIN + threshold |
| Over-Provisioned Licenses | ❌ | Need M365 usage data (not collected) |
| Orphaned Groups | ✅ | `memberCountTotal = 0` |
| Guest Access Review | ✅ | `userType = Guest` + edges |
| External App Access | ✅ | `oauth2PermissionGrant` edges |
| Historical Trends | ❌ | Requires metrics container |
| Compliance Frameworks | 🔧 | Need control mapping design |

### Operational Intelligence

| Insight | Status | Notes |
|---------|--------|-------|
| Daily Changes | ✅ | Audit container counts |
| Privileged Changes | ⚠️ | Audit + filter by admin roles |
| Policy Modifications | ✅ | CA policies in audit with change tracking |
| Legacy Auth Usage | ❌ | Don't collect sign-in logs |
| Risky Sign-Ins | ❌ | Don't collect sign-in logs |

---

**End of Document**
