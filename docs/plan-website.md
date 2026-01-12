# Alpenglow Dashboard - Implementation Proposal

**Document Purpose**: Critical analysis of Website 2 Design.md and implementation proposal for the Alpenglow Dashboard.

**Related Documents**:
- UI Design: [Website 2 Design.md](Website%202%20Design.md)
- Architecture: [final architecture.md](final%20architecture.md)
- Task List: [claude-to-do-reference.md](claude-to-do-reference.md)

---

## Executive Summary

| Decision | Outcome |
|----------|---------|
| **Primary Users** | Security analysts (primary) + Less technical managers (secondary) |
| **Approach** | Phase 1: Enhance debug dashboard → Phase 2: Build Alpenglow |
| **Historical Trends** | Critical - requires backend work for metrics collection |

---

## The Data Gold Mine - Value Propositions

You collect **5 entity types, 15+ edge types, 50+ derived abuse edges, and 100+ dangerous permissions** across Entra ID and Azure. Here's how to turn that into compelling dashboards:

### 1. SECURITY RISK INSIGHTS (Primary Value)

#### "Who Can Compromise the Tenant?"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Tier 0 Exposure** | Users with Global Admin, Privileged Role Admin, App Admin | Card: "X users can take over the entire tenant" |
| **MFA-less Admins** | Privileged users with `perUserMfaState != enforced` | RED ALERT: "3 Global Admins have no MFA" |
| **Shortest Path to Admin** | Chain: User → Group → PIM Eligible → Global Admin | Attack path visualization |
| **Shadow Admins** | Users who own apps/groups that have admin roles | "15 users have hidden admin access via ownership" |

#### "Cross-Cloud Risk"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Entra → Azure Escalation** | SP with Graph perms + Azure RBAC Owner | "4 apps can pivot from Entra to Azure Owner" |
| **VM Code Execution Paths** | Users → Groups → Azure VM Contributor | "Who can run code on your VMs?" |
| **Key Vault Exposure** | Key Vault access policies + RBAC | "Secrets accessible by X identities" |

#### "Credential Risk"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Expiring Secrets** | App/SP `passwordCredentials` with near expiry | "12 app secrets expire in < 30 days" |
| **Apps with Dangerous Perms** | `DangerousPermissions.psd1` matches | "5 apps can read all email (Mail.ReadWrite)" |
| **Over-Permissioned SPs** | SPs with > 5 Graph permissions | "Service principals with excessive access" |

### 2. COMPLIANCE & GOVERNANCE (Management Value)

#### "Policy Coverage Dashboard"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **MFA Coverage** | Users with MFA / Total users | Gauge: "78% MFA adoption" |
| **CA Policy Gaps** | Users excluded from CA policies | "156 users bypass Require MFA policy" |
| **PIM Adoption** | Eligible vs Permanent assignments | "65% of admin roles use PIM" |
| **Device Compliance** | `isCompliant` flag on devices | "89% device compliance rate" |

#### "Privileged Access Governance"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Admin Sprawl** | Count of Global Admins over time | Trend: "Global Admins: 8 → 12 in 90 days" |
| **Permanent vs Eligible** | directoryRole vs pimEligible edges | Pie chart: assignment types |
| **Stale Privileged Accounts** | Admins with no sign-in > 30 days | "2 admins haven't signed in for 60+ days" |

### 3. BUSINESS VALUE (Executive Buy-In)

#### "Cost Optimization"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Unused Licenses** | `assignedLicenseSkus` vs `lastSignInDateTime` | "$4,200/month in unused E5 licenses" |
| **Orphaned Resources** | Groups with 0 members, apps with 0 users | "47 orphaned objects to clean up" |
| **Guest Sprawl** | External users with privileged access | "23 guests have access to sensitive groups" |

#### "Audit Readiness"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Privileged Access Review** | All admin assignments with last activity | Export-ready report for auditors |
| **Policy Compliance** | Security defaults + CA + MFA status | "Audit checklist: 8/10 controls met" |
| **Change Documentation** | Audit container with who/what/when | "All changes to admin roles in last 90 days" |

### 4. OPERATIONAL INTELLIGENCE (SOC Value)

#### "Attack Surface Monitoring"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Public-Facing Resources** | Storage with public access, Key Vaults without private endpoint | "5 storage accounts have public blob access" |
| **Legacy Auth Usage** | Sign-ins with Basic Auth | "142 legacy auth sign-ins this week" |
| **Risky Sign-In Patterns** | Sign-in events with risk flags | "7 sign-ins from risky locations" |

#### "Change Velocity"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **Daily Changes** | Audit container counts | Trend: "Avg 47 changes/day, spike to 200 yesterday" |
| **Privileged Changes** | Admin role additions/removals | Alert: "New Global Admin added" |
| **Policy Modifications** | CA policy changes | "CA policy 'Block Legacy Auth' was modified" |

### 5. INVESTIGATION & INCIDENT RESPONSE (SOC Deep Dive)

#### "Blast Radius Analysis"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **User Impact** | Given user → all accessible resources | "If user X is compromised, they can access..." |
| **Group Impact** | Given group → all members + their access | "Group Y has 47 members with access to..." |
| **App Takeover** | Given app → all permissions + owners | "App Z has Mail.ReadWrite + 2 owners who could be targeted" |

#### "Lateral Movement Paths"
| Insight | Data Source | Dashboard Element |
|---------|-------------|-------------------|
| **From Any User** | Starting point → all reachable admin roles | Interactive: "Select user, see escalation paths" |
| **Group Nesting Exploits** | Groups with `nestingDepth > 3` | "These groups have hidden membership chains" |
| **Cross-Tenant Risk** | Guest users with privileged access | "External users who could escalate" |

---

## Priority Features Based on Value

### MUST HAVE (Immediate differentiators)

| Feature | Value | Effort |
|---------|-------|--------|
| **"Who can take over the tenant?" card** | CRITICAL - unique insight | Medium |
| **MFA-less admins alert** | HIGH - actionable finding | Low |
| **Expiring credentials list** | HIGH - prevents outages | Low |
| **License waste calculator** | HIGH - $ savings | Low |
| **CA policy coverage gaps** | HIGH - security blind spots | Medium |

### SHOULD HAVE (Compelling additions)

| Feature | Value | Effort |
|---------|-------|--------|
| **Attack path visualization** | HIGH - visual impact | High |
| **Privilege change trends** | MEDIUM - historical context | Medium |
| **Cross-cloud escalation paths** | HIGH - unique insight | Medium |
| **Blast radius calculator** | HIGH - incident response | Medium |

### NICE TO HAVE (Future polish)

| Feature | Value | Effort |
|---------|-------|--------|
| **Comparison to industry benchmarks** | MEDIUM | High |
| **Automated remediation suggestions** | HIGH | High |
| **Integration with ticketing systems** | MEDIUM | Medium |

---

## Landing Page Hero Metrics

These are the "headline" numbers that immediately communicate value:

### Security Posture Cards (5 cards, redesigned)

| Card | Headline Metric | Supporting Metrics | Why It Matters |
|------|-----------------|--------------------|-----------------|
| **Tenant Takeover Risk** | "8 users can compromise entire tenant" | - 3 Global Admins<br>- 2 Privileged Role Admins<br>- 3 via ownership chains | This is THE differentiator. No other tool shows this so clearly. |
| **MFA Gaps** | "12 privileged users without MFA" | - 3 Global Admins<br>- 5 with legacy auth<br>- 4 with weak methods | Directly actionable, high urgency. |
| **Credential Exposure** | "23 secrets expire in 30 days" | - 8 apps<br>- 15 service principals<br>- $0 Key Vault secrets | Prevents outages, shows proactive monitoring. |
| **Policy Coverage** | "78% protected by MFA policy" | - 156 users excluded<br>- 12 apps bypassed<br>- 3 policy conflicts | Shows CA effectiveness and gaps. |
| **Cost Opportunity** | "$4,200/month recoverable" | - 47 unused E5 licenses<br>- 23 inactive 90+ days<br>- 12 guest with licenses | Immediate ROI justification. |

### Alternative Card Options

| Card | Headline | Supporting | Use Case |
|------|----------|------------|----------|
| **Cross-Cloud Risk** | "4 apps can pivot to Azure Owner" | SP permissions + RBAC | For orgs with significant Azure footprint |
| **Guest Risk** | "23 external users with privileged access" | Guest + group membership + roles | For orgs with heavy B2B collaboration |
| **Device Compliance** | "89% devices compliant" | By OS, by policy | For Intune-heavy environments |
| **Change Velocity** | "47 changes/day (↑15% vs last week)" | By type, by criticality | For mature SOC teams |

---

## Proposed Dashboard Sections (Redesigned)

Instead of the original 5 sections, consider organizing by **use case**:

### Section 1: Executive Summary (Landing Page)
- Hero metrics (5 cards above)
- 90-day trend charts
- Recent critical changes

### Section 2: Risk Explorer
- **Tier 0 Exposure**: All paths to Global Admin
- **Cross-Cloud Paths**: Entra → Azure escalation
- **Credential Risks**: Expiring, over-permissioned, dangerous

### Section 3: Compliance Dashboard
- MFA coverage by user type
- CA policy coverage matrix
- PIM adoption metrics
- Device compliance by OS

### Section 4: Cost & Cleanup
- License optimization
- Orphaned objects
- Stale accounts
- Guest access review

### Section 5: Investigation (SOC)
- Blast radius calculator
- Change timeline
- Entity deep-dive
- Export for SIEM

### Section 6: Data Browser (Debug Dashboard replacement)
- Raw data tables (current functionality)
- Filtering and export
- Audit trail

---

## Critical Analysis of Website 2 Design.md

### What's Solid

| Aspect | Assessment |
|--------|------------|
| **Design Philosophy** | "Information density and functional clarity" is exactly right for security analysts |
| **Data Freshness Awareness** | Correct emphasis on snapshot-based data, not real-time |
| **Visual Design System** | Color palette, typography, spacing are well-defined and consistent |
| **Security Posture Cards** | High-value concept - executives and analysts both want at-a-glance status |
| **Layout Structure** | Standard sidebar + content pattern is proven and familiar |

### What's Problematic

| Issue | Severity | Analysis |
|-------|----------|----------|
| **Scope is Massive** | HIGH | The design describes a feature-complete SPA. Current debug dashboard is ~560 lines. This would be 10-20x larger. |
| **No Tech Stack Decision** | HIGH | Document discusses static demo site stack but not production. Is this server-rendered? SPA? This fundamentally affects everything. |
| **Historical Trends Assume Data Exists** | HIGH | 90-day trends require historical snapshots. We only have current state + recent audit changes. Backend work needed first. |
| **Relationship Visualization Unsolved** | MEDIUM | Notes say "Gremlin won't be implemented" but design still shows relationships. The table approach in debug dashboard already works. What's the actual improvement? |
| **Search with Autocomplete** | MEDIUM | Requires either client-side index (memory) or API endpoint (backend work). Neither exists. |
| **Detail Panels** | LOW | Nice UX polish but adds complexity. Current click-to-see-details in table works. |
| **Mobile Responsiveness** | LOW | Security analysts use desktops. Mobile is likely low priority. |

### What's Missing

1. **Target User Definition**: Who exactly uses this? Developers (debug dashboard covers this), Security Analysts, Executives, Compliance? Each has different needs.

2. **MVP Definition**: What's the minimum that delivers value?

3. **Backend Requirements**: Which features need backend changes vs pure frontend?

4. **Tech Stack Decision**: React? Vue? Plain JS? Server-rendered? This affects every implementation decision.

5. **Authentication/Authorization**: How do users access this? Entra ID integration? Role-based views?

6. **Data Refresh Strategy**: Live polling? Manual refresh? Push notifications?

---

## Feature ROI Matrix

| Feature | User Value | Effort | ROI | Recommendation |
|---------|------------|--------|-----|----------------|
| **Security Posture Cards (Landing Page)** | HIGH | MEDIUM | **HIGH** | Priority 1 - Clear executive value |
| **License Analysis (Cost Savings)** | HIGH | LOW | **HIGH** | Priority 2 - Immediate business value for managers |
| **Better Table Filtering/Sorting** | HIGH | LOW | **HIGH** | Priority 3 - Low effort, high utility |
| **Historical Trend Charts** | HIGH | HIGH | **MEDIUM** | Priority 4 - Needs backend work first |
| **Global Search** | MEDIUM | MEDIUM | MEDIUM | Priority 5 - Useful but current tables work |
| **Navigation Sidebar** | MEDIUM | LOW | MEDIUM | Priority 6 - Standard improvement |
| **Detail Panels (Slide-in)** | LOW | MEDIUM | LOW | Defer - Nice polish, not essential |
| **Relationship Visualization** | MEDIUM | HIGH | LOW | Defer - Tables work, Gremlin is V4+ |
| **Static Demo Site** | LOW | MEDIUM | LOW | Defer - Marketing, not user value |
| **Mobile Responsiveness** | LOW | MEDIUM | LOW | Skip - Not target use case |

---

## Historical Trends - Backend Requirements

Since historical trends are critical for launch, backend work is required:

### Options

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| Store full snapshots daily | Complete history, any query possible | Storage grows linearly, ~1GB/90 days | Too heavy |
| **Store aggregated metrics only** | Tiny storage (~KB/day), fast queries | Limited to pre-defined metrics | **Recommended** |
| Query audit container | No new storage | Complex queries, may miss data | Fallback option |

### Recommended Metrics to Track Daily

```
Security Posture Metrics:
- Total users (enabled/disabled)
- Users with MFA / without MFA
- Users with risk levels (none/low/medium/high)
- Total groups
- Total service principals
- Privileged role assignments (permanent/eligible)
- Global admin count
- CA policies (enabled/disabled/report-only)

Business Value Metrics:
- Unused licenses count (no sign-in > 30/60/90 days)
- License cost opportunity ($ potential savings)
- License utilization by SKU
```

### Implementation

1. Create new Cosmos DB container: `metrics` (partition key: `/date`)
2. Add `CollectMetrics` function to Orchestrator (runs after indexing)
3. Store one document per day with all metrics
4. Implement 90-day TTL for automatic cleanup

---

## License Optimization - Business Value Quick Win

This demonstrates immediate value to managers:

| Metric | Value Proposition | Implementation |
|--------|-------------------|----------------|
| **Unused licenses** | "23 users haven't signed in for 90 days - $X/month potential savings" | Compare `assignedLicenseSkus` vs `lastSignInDateTime` |
| **License by SKU** | "You have 50 E5 licenses but only 30 are active users" | Group by SKU, count active vs inactive |
| **Cost summary** | "$2,500/month could be saved by removing unused licenses" | Map SKUs to known costs, calculate totals |

---

## Technical Decisions

### Tech Stack Recommendation

| Component | Recommendation | Rationale |
|-----------|----------------|-----------|
| **Phase 1 (Debug Dashboard)** | Enhanced PowerShell | No new tech, fast iteration, already works |
| **Phase 2 (Alpenglow)** | Plain HTML/CSS/JS + Chart.js | Simple, no build step, easy to host as static site |
| **Data Source** | Cosmos DB input bindings (existing pattern) | Already proven, no new infrastructure |
| **Authentication** | Azure AD Easy Auth | Built-in to Azure Functions, low complexity |
| **Charts** | Chart.js | Lightweight, well-documented, no dependencies |

### Data Strategy

| Question | Decision |
|----------|----------|
| How does frontend get data? | Cosmos DB input bindings (same as debug dashboard) |
| Historical data for trends? | New `metrics` container with daily aggregations |
| Real-time or snapshot? | Snapshot with manual refresh button |

---

## Phased Implementation Plan

### Phase 1: Debug Dashboard Enhancements + Backend Prep
**Timeline**: 2 weeks

**Frontend (Debug Dashboard):**
- [ ] Add Security Posture Summary section at top
- [ ] Add License Analysis section (unused licenses, potential savings by SKU)
- [ ] Add per-column filter inputs to all tables
- [ ] Add CSV export buttons to all tables
- [ ] Rename to "Debug Dashboard" in HTML title/header

**Backend (Historical Trends Foundation):**
- [ ] Design metrics schema for daily aggregation
- [ ] Create `metrics` container in Cosmos DB
- [ ] Add `CollectMetrics` function to Orchestrator
- [ ] Implement 90-day TTL retention policy

### Phase 2: Alpenglow Dashboard (Separate Function App)
**Timeline**: 2-3 weeks
**Prerequisite**: Phase 1 complete

- [ ] Create Function App 2 infrastructure (Bicep/ARM)
- [ ] Configure Managed Identity with read-only Cosmos access
- [ ] Build landing page with security posture cards
- [ ] Build historical trend charts (4 charts from metrics container)
- [ ] Build License optimization view (manager-friendly)
- [ ] Build Principals view (users, groups, SPs, devices)
- [ ] Build Policies view (CA, auth methods)
- [ ] Configure Azure AD Easy Auth

### Phase 3: Advanced Features (V4+)
**Timeline**: TBD
**Prerequisite**: Phase 2 deployed, user feedback collected

- [ ] Relationship visualization improvements (post-Gremlin)
- [ ] Detail panels (slide-in)
- [ ] Global search with autocomplete
- [ ] Advanced filtering / saved views
- [ ] Static demo site (marketing)

---

## What to Explicitly Defer

| Feature | Why Defer |
|---------|-----------|
| **Relationship Visualization** | Gremlin integration is V4+. Tables work fine for now. |
| **Mobile Responsiveness** | Security analysts use desktops. Low priority. |
| **Static Demo Site** | Marketing asset, not user-facing value. |
| **Detail Panels** | Nice UX polish but not essential for MVP. |

---

## Success Metrics

How we'll know the dashboard is delivering value:

| Metric | Target |
|--------|--------|
| **User Adoption** | Security team uses it weekly |
| **Manager Engagement** | License report reviewed monthly |
| **Cost Savings Identified** | $X/month in unused licenses found |
| **Time Saved** | Analysts find info faster than Entra portal |

---

## Next Steps

1. **Approve this plan** and add Phase 1 tasks to sprint
2. **Design metrics schema** for historical trends
3. **Start Phase 1 frontend work** (Security Posture Summary section)
4. **Start Phase 1 backend work** (metrics container and collection)
