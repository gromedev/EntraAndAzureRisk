# Hmm...

Actually this whole idea is shit... 
Let's just focus on 
-- when users share, send documents to external partieis. Think DLP
-- how much storage they are using in OneDrive and Sharepoint

Unless purview takes care of that

-------------------

# USER NOTES
We will not be imoplementing
- Teams related stuff 
- Power BI related stuff (but will take Power BI into consideration in case users want to import the data themselves. We are simply structuring the data. They will have to make the code changes themselves)
- Lets just focus on 
-- when users share, send documents to external partieis. Think DLP
-- how much storage they are using in OneDrive and Sharepoint



# M365 Usage Data Collection - Design Document

**Version**: 1.0
**Created**: 2026-01-12
**Status**: Planning

---

## Purpose

Add Microsoft 365 usage data collection to enable **license optimization insights**:
- Detect over-provisioned licenses (E5 user only using E3 features)
- Identify which M365 services each user actually uses
- Calculate potential cost savings from license downgrades

---

## What is M365 Usage Data?

Microsoft Graph provides usage reports showing which M365 services and apps each user has accessed over time periods (7, 30, 90, or 180 days).

### Available Data Points

| Service | What It Shows | API Endpoint |
|---------|---------------|--------------|
| **Office 365 Active Users** | Which services each user accessed (Exchange, SharePoint, OneDrive, Teams, Yammer) | `/reports/getOffice365ActiveUserDetail` |
| **M365 Apps** | Which apps used (Word, Excel, PowerPoint, Outlook, OneNote, Teams) and on which platforms | `/reports/getM365AppUserDetail` |
| **Exchange** | Emails sent/received, mailbox size | `/reports/getEmailActivityUserDetail` |
| **OneDrive** | Files viewed, edited, synced, shared | `/reports/getOneDriveActivityUserDetail` |
| **SharePoint** | Files viewed, edited, shared, pages visited | `/reports/getSharePointActivityUserDetail` |
| **Teams** | Messages, calls, meetings | `/reports/getTeamsUserActivityUserDetail` |

### Key Fields from `getOffice365ActiveUserDetail`

```
userPrincipalName
displayName
isDeleted
deletedDate
hasExchangeLicense
hasOneDriveLicense
hasSharePointLicense
hasSkypeForBusinessLicense
hasYammerLicense
hasTeamsLicense
exchangeLastActivityDate
oneDriveLastActivityDate
sharePointLastActivityDate
skypeForBusinessLastActivityDate
yammerLastActivityDate
teamsLastActivityDate
exchangeLicenseAssignDate
oneDriveLicenseAssignDate
sharePointLicenseAssignDate
skypeForBusinessLicenseAssignDate
yammerLicenseAssignDate
teamsLicenseAssignDate
assignedProducts
```

---

## Graph API Details

### Permissions Required

| Permission | Type | Description |
|------------|------|-------------|
| `Reports.Read.All` | Application | Read all usage reports |

**Note**: This is a sensitive permission. The admin may have configured "concealed user details" which replaces usernames with GUIDs. Check tenant settings.

### API Call Examples

```http
GET /reports/getOffice365ActiveUserDetail(period='D30')
Accept: application/json
```

**Response format options:**
- CSV (default) - smaller, but needs parsing
- JSON - larger, but native format

**Period options:** `D7`, `D30`, `D90`, `D180`

### Rate Limits & Caching

- Usage reports are generated daily, typically with 24-48 hour delay
- Reports are cached by Microsoft - same request returns cached data
- No need to call more than once per day

---

## License Tier Analysis

### Microsoft 365 License Tiers

| License | Approx. Cost/User/Month | Key Features |
|---------|-------------------------|--------------|
| **E5** | $57 | Everything + Advanced security, eDiscovery, Power BI Pro |
| **E3** | $36 | Core apps + Security baseline |
| **E1** | $10 | Web/mobile only, no desktop apps |
| **F3** (Frontline) | $8 | Limited, for frontline workers |
| **Business Premium** | $22 | SMB equivalent of E3 |

### Over-Provisioning Detection Logic

A user is **over-provisioned** if they have E5 but:

| Scenario | Detection | Recommendation |
|----------|-----------|----------------|
| Only uses Exchange/Teams | `sharePointLastActivityDate = null` AND `oneDriveLastActivityDate = null` for 90 days | Downgrade to E1 + Teams |
| Uses basic Office apps | No advanced security features, no Power BI, no eDiscovery | Downgrade to E3 |
| Only uses web apps | No desktop app usage in M365 Apps report | Downgrade to E1 |
| No activity at all | All `*LastActivityDate` fields null | Remove license entirely |

### ROI Calculation

```
E5 → E3 savings: $57 - $36 = $21/user/month = $252/user/year
E5 → E1 savings: $57 - $10 = $47/user/month = $564/user/year
E5 → Remove:     $57/user/month = $684/user/year
```

For 1000 users with 10% over-provisioned:
- 100 users × $252/year = **$25,200/year potential savings**

---

## Implementation Options

### Option A: Add to Existing Collection (Recommended)

Add a new collector function `CollectM365Usage` to Function App 1.

**Pros:**
- Uses existing infrastructure
- Data stored alongside other principal data
- Can enrich users with usage fields

**Cons:**
- Adds another permission to already-privileged Function App 1

### Option B: Separate Function App

Create a dedicated Function App for usage reports.

**Pros:**
- Permission isolation
- Could run less frequently (weekly vs 6-hourly)

**Cons:**
- More infrastructure complexity
- Need to JOIN data in dashboard

### Option C: Dashboard-Only (Just-in-Time)

Query usage reports only when dashboard is viewed.

**Pros:**
- No storage needed
- Always fresh data

**Cons:**
- Slow dashboard load (report generation takes seconds)
- Can't track trends over time
- Rate limiting concerns

**Recommendation**: **Option A** - Add to existing collection, run weekly.

---

## Data Model

### New Fields on User Principal

Add these fields to the `principals` container for users:

```javascript
{
  // Existing user fields...

  // NEW: M365 Usage fields
  "m365Usage": {
    "reportDate": "2026-01-10",
    "hasExchangeLicense": true,
    "hasTeamsLicense": true,
    "hasSharePointLicense": true,
    "hasOneDriveLicense": true,
    "exchangeLastActivity": "2026-01-09",
    "teamsLastActivity": "2026-01-10",
    "sharePointLastActivity": "2026-01-05",
    "oneDriveLastActivity": null,
    "assignedProducts": ["Microsoft 365 E5"],
    "usageScore": 2,  // 0-5 based on services used
    "licenseTierRecommendation": "E3"  // Calculated field
  }
}
```

### Usage Score Calculation

| Score | Meaning | Services Used |
|-------|---------|---------------|
| 0 | Inactive | None in 90 days |
| 1 | Minimal | Only 1 service |
| 2 | Light | 2 services |
| 3 | Moderate | 3 services |
| 4 | Active | 4 services |
| 5 | Power User | All services |

---

## Implementation Plan

### Phase 1: Basic Collection

| Task | Effort | Notes |
|------|--------|-------|
| Add `Reports.Read.All` permission to Function App 1 | 0.5 day | Update Bicep + consent |
| Create `CollectM365Usage/run.ps1` | 1 day | Call API, parse CSV, create enrichment records |
| Add usage fields to `IndexerConfigs.psd1` | 0.5 day | Define indexing for new fields |
| Update `IndexPrincipalsInCosmosDB` to merge usage data | 0.5 day | JOIN on UPN |
| Add usage columns to Dashboard | 0.5 day | Show in Users table |

**Total: ~3 days**

### Phase 2: License Optimization View

| Task | Effort | Notes |
|------|--------|-------|
| Add license tier detection logic | 1 day | Map SKUs to tiers |
| Add recommendation engine | 1 day | Calculate optimal license per user |
| Add Cost Savings card to dashboard | 0.5 day | Aggregate potential savings |
| Add License Optimization tab | 1 day | Detailed breakdown |

**Total: ~3.5 days**

### Phase 3: Trend Tracking

| Task | Effort | Notes |
|------|--------|-------|
| Store weekly usage snapshots in `metrics` container | 0.5 day | Track usage trends |
| Add usage trend charts | 1 day | Show adoption over time |

**Total: ~1.5 days**

---

## Collector Implementation

### `CollectM365Usage/run.ps1` (Draft)

```powershell
# Collect M365 Usage Reports
param($name)

$token = Get-ManagedIdentityToken -Resource "https://graph.microsoft.com"
$headers = @{ Authorization = "Bearer $token" }

# Get Office 365 Active User Detail (30 days)
$uri = "https://graph.microsoft.com/v1.0/reports/getOffice365ActiveUserDetail(period='D30')"
$response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

# Response is CSV - parse it
$usageData = $response | ConvertFrom-Csv

# Transform to enrichment records
$enrichmentRecords = foreach ($user in $usageData) {
    @{
        id = $user.'User Principal Name'
        entityType = 'm365UsageEnrichment'
        userPrincipalName = $user.'User Principal Name'
        reportDate = (Get-Date).ToString('yyyy-MM-dd')
        hasExchangeLicense = $user.'Has Exchange License' -eq 'True'
        hasTeamsLicense = $user.'Has Teams License' -eq 'True'
        hasSharePointLicense = $user.'Has SharePoint License' -eq 'True'
        hasOneDriveLicense = $user.'Has OneDrive License' -eq 'True'
        exchangeLastActivity = $user.'Exchange Last Activity Date'
        teamsLastActivity = $user.'Teams Last Activity Date'
        sharePointLastActivity = $user.'SharePoint Last Activity Date'
        oneDriveLastActivity = $user.'OneDrive Last Activity Date'
        assignedProducts = $user.'Assigned Products' -split '\+' | ForEach-Object { $_.Trim() }
    }
}

# Output as JSONL to blob storage
$jsonl = $enrichmentRecords | ForEach-Object { $_ | ConvertTo-Json -Compress }
$jsonl | Out-File -FilePath "$env:TEMP/m365usage.jsonl"

Push-OutputBinding -Name outputBlob -Value (Get-Content "$env:TEMP/m365usage.jsonl" -Raw)
```

---

## Dashboard Integration

### Users Table Enhancement

Add columns to the Users table:

| Column | Source | Display |
|--------|--------|---------|
| Usage Score | `m365Usage.usageScore` | 0-5 badge |
| Last Activity | Latest of all `*LastActivity` dates | "3 days ago" |
| License Recommendation | `m365Usage.licenseTierRecommendation` | "E3 ↓" badge |

### License Optimization Card

```
┌─────────────────────────────────────────┐
│ LICENSE OPTIMIZATION                     │
├─────────────────────────────────────────┤
│                                          │
│  Over-Provisioned Users:  47            │
│  Potential Monthly Savings: $1,692      │
│  Potential Annual Savings: $20,304      │
│                                          │
│  [View Details →]                        │
└─────────────────────────────────────────┘
```

---

## Privacy & Compliance Considerations

### User Identification

By default, Microsoft may obfuscate user identities in reports (tenant setting). To get real UPNs:

1. Go to Microsoft 365 Admin Center
2. Settings → Org Settings → Reports
3. Uncheck "Display concealed user, group, and site names in all reports"

### Data Retention

- Microsoft retains usage reports for 180 days
- Consider storing aggregated data longer for trend analysis
- PII considerations: Store only what's needed

### Audit Trail

- Log when usage data is collected
- Note: This data could be sensitive (shows user activity patterns)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| User identity concealed in reports | Can't match to users | Document admin requirement to disable concealment |
| Reports delayed 24-48 hours | Data slightly stale | Acceptable for license optimization use case |
| Large tenant = large report | Memory/performance | Stream/paginate, run during off-hours |
| Permission scope creep | Security concern | Document justification, consider separate Function App |

---

## Success Metrics

| Metric | Target |
|--------|--------|
| Users with usage data | >95% of licensed users |
| License recommendations generated | 100% of over-provisioned users identified |
| Dashboard load time impact | <2 seconds additional |
| Cost savings identified | Measurable $ value |

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `Reports.Read.All` permission | Not granted | Requires admin consent |
| User identity visibility | Unknown | Check tenant settings |
| Metrics container | Not created | Needed for Phase 3 trends |

---

## Next Steps

1. **Verify tenant settings** - Can we see real UPNs in reports?
2. **Add permission** - Request `Reports.Read.All` consent
3. **Prototype collector** - Test API, verify data quality
4. **Decide on collection frequency** - Daily vs weekly

---

## References

- [Microsoft Graph Reports API](https://learn.microsoft.com/en-us/graph/api/resources/report)
- [getOffice365ActiveUserDetail](https://learn.microsoft.com/en-us/graph/api/reportroot-getoffice365activeuserdetail)
- [M365 Admin Center - Reports Settings](https://admin.microsoft.com/Adminportal/Home#/Settings/Services/:/Settings/L1/Reports)


# Detecting Over-Provisioned E5 Licenses - Deep Dive

**Version**: 1.0
**Created**: 2026-01-12
**Status**: Research

---

## The Problem

A user has an E5 license ($57/month) and signs in regularly, but are they actually using E5-exclusive features? Or could they function perfectly well on E3 ($36/month) or even E1 ($10/month)?

**The challenge**: Basic usage reports only show *if* a user accessed Exchange/Teams/SharePoint. They don't show *which premium features* they used.

---

## What Makes E5 Different?

### E5 vs E3 Feature Comparison

| Category | E5 Exclusive Features | E3 Includes |
|----------|----------------------|-------------|
| **Security** | Defender for Office 365 P2, Defender for Endpoint P2, Defender for Identity, Defender for Cloud Apps | Basic protection |
| **Compliance** | eDiscovery Premium, Advanced Audit, Communication Compliance, Insider Risk Management, Information Barriers | Basic eDiscovery, Standard Audit |
| **Analytics** | Power BI Pro, MyAnalytics/Viva Insights (full) | None / Limited |
| **Voice** | Phone System, Audio Conferencing | None |
| **Information Protection** | Azure Information Protection P2, Auto-labeling | AIP P1 |
| **Identity** | Azure AD P2 (PIM, Identity Protection, Access Reviews) | Azure AD P1 |

### The Key Question

**Is the user actively benefiting from ANY of these E5-exclusive features?**

If not → They're over-provisioned.

---

## Detection Strategies

### Strategy 1: Feature-by-Feature Usage Detection

Check if user is actively using each E5 feature via different APIs.

| E5 Feature | Detection Method | API/Data Source | Feasibility |
|------------|------------------|-----------------|-------------|
| **Defender for Endpoint** | Device enrolled, alerts generated | Microsoft 365 Defender API | Medium |
| **Defender for Office 365** | Safe Links/Attachments clicks, phishing reports | Office 365 Management API | Medium |
| **Defender for Identity** | Alerts, coverage | Defender for Identity API | Medium |
| **Defender for Cloud Apps** | App discoveries, policies | Cloud App Security API | Medium |
| **eDiscovery Premium** | Is case custodian or reviewer | Compliance Center API | Hard |
| **Power BI Pro** | Reports viewed/created | Power BI Admin API | Easy |
| **Audio Conferencing** | PSTN calls made | Teams PSTN Usage Reports | Easy |
| **Phone System** | Calls made/received | Teams Call Records API | Easy |
| **PIM** | Active/eligible role assignments | Graph API (already have!) | ✅ Easy |
| **Identity Protection** | Risk events, policies applied | Graph API (already have!) | ✅ Easy |
| **Access Reviews** | Reviewer assignments | Graph API | Easy |
| **Advanced Audit** | Premium audit events | Unified Audit Log | Medium |
| **Insider Risk** | Policy assignments | Compliance Center API | Hard |
| **Information Barriers** | Segment assignments | Graph API | Medium |

### Strategy 2: License Dependency Analysis

Some E5 features are tenant-wide enablers, not per-user features. A user might "benefit" from E5 without direct usage:

| Feature Type | Example | Per-User Detectable? |
|--------------|---------|---------------------|
| **Active Usage** | User creates Power BI reports | Yes |
| **Passive Protection** | Defender scans their email | Partially (alerts) |
| **Tenant Capability** | eDiscovery can search their mailbox | No |
| **Role-Based** | User is an eDiscovery reviewer | Yes (role check) |

### Strategy 3: Workload-Based Scoring

Score each user based on workload sophistication:

```
E5 Score =
  (Uses Power BI Pro features) × 2 +
  (Makes PSTN calls) × 2 +
  (Has PIM role assignments) × 1 +
  (Has Defender alerts) × 1 +
  (Uses advanced compliance features) × 2 +
  (Is eDiscovery reviewer) × 2

0-1: Likely over-provisioned (recommend E3 or E1)
2-3: Possibly over-provisioned (review manually)
4+:  Appropriately licensed
```

---

## APIs for Detection

### 1. Power BI Usage (Easy)

**API**: Power BI Admin REST API

```http
GET https://api.powerbi.com/v1.0/myorg/admin/reports
GET https://api.powerbi.com/v1.0/myorg/admin/users/{userPrincipalName}/reports
```

**Permission**: `Tenant.Read.All` (Power BI Admin API)

**What it shows**: Reports created, dashboards, workspaces

**Detection**: User has Power BI activity → E5 feature used

### 2. Teams PSTN Usage (Easy)

**API**: Microsoft Graph

```http
GET /reports/getPstnCalls
GET /reports/getDirectRoutingCalls
```

**Permission**: `CallRecords.Read.All`

**What it shows**: Users making/receiving PSTN calls

**Detection**: User has PSTN call records → E5 Phone System used

### 3. Audio Conferencing (Easy)

**API**: Microsoft Graph

```http
GET /communications/callRecords
GET /reports/getTeamsUserActivityUserDetail
```

**What it shows**: Dial-in conference participation

**Detection**: User joins meetings via dial-in → E5 Audio Conferencing used

### 4. PIM Usage (Already Have!)

We already collect `pimEligible` edges!

**Detection**: User has PIM role assignment → E5 Azure AD P2 feature used

### 5. Identity Protection (Already Have!)

We already collect `riskLevel` and `riskState` on users!

**Detection**: User has been evaluated by Identity Protection → E5 feature active

### 6. Defender for Endpoint

**API**: Microsoft 365 Defender API

```http
GET https://api.securitycenter.microsoft.com/api/machines
GET https://api.securitycenter.microsoft.com/api/alerts
```

**Permission**: `Machine.Read.All`, `Alert.Read.All`

**What it shows**: Devices with Defender, alerts per user

**Detection**: User's device has Defender alerts → E5 feature protecting them

### 7. Defender for Office 365

**API**: Office 365 Management Activity API

```http
GET /api/v1.0/{tenant}/activity/feed/subscriptions/content?contentType=Audit.Exchange
```

**What it shows**: Safe Links clicks, Safe Attachments detonations, phishing reports

**Detection**: User triggered Safe Links/Attachments → E5 feature used

### 8. eDiscovery Role Check

**API**: Microsoft Graph

```http
GET /roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{eDiscoveryRoleId}'
```

**Role IDs**:
- eDiscovery Manager: `246d91f7-6e91-4c65-bf4d-...`
- eDiscovery Administrator: `...`

**Detection**: User has eDiscovery role → E5 compliance feature used

### 9. Access Reviews

**API**: Microsoft Graph

```http
GET /identityGovernance/accessReviews/definitions
GET /identityGovernance/accessReviews/definitions/{id}/instances/{instanceId}/decisions
```

**Permission**: `AccessReview.Read.All`

**Detection**: User is reviewer in access reviews → E5 Azure AD P2 used

### 10. Advanced Audit Events

**API**: Unified Audit Log (via Compliance Center or Management API)

Check if user generates "AdvancedAudit" events (E5 feature):
- MailItemsAccessed
- Send (specific conditions)
- SearchQueryInitiatedExchange
- SearchQueryInitiatedSharePoint

**Detection**: User has advanced audit events → E5 compliance used

---

## Implementation Approach

### Phase 1: Low-Hanging Fruit (What We Can Do Now)

Use data we already collect or can easily add:

| Feature | Data Source | Implementation |
|---------|-------------|----------------|
| **PIM Usage** | `pimEligible` edges | Already have! Count users with PIM |
| **Identity Protection** | `riskLevel`, `riskState` fields | Already have! Non-null = IP active |
| **Basic M365 Usage** | `getOffice365ActiveUserDetail` | Add per M365-usage.md |

**Quick Win**: Users with E5 + no PIM assignments + no risk evaluation + low usage score = **over-provisioned candidates**

### Phase 2: Add Key E5 Usage APIs

| API | Permission | Effort | Value |
|-----|------------|--------|-------|
| **Power BI Admin** | `Tenant.Read.All` (Power BI) | 1 day | High - clear signal |
| **PSTN Usage** | `CallRecords.Read.All` | 0.5 day | High - clear signal |
| **Access Reviews** | `AccessReview.Read.All` | 0.5 day | Medium |

### Phase 3: Advanced Detection

| API | Permission | Effort | Value |
|-----|------------|--------|-------|
| **Defender for Endpoint** | Security Center API | 2 days | Medium |
| **Defender for Office 365** | Management Activity API | 2 days | Medium |
| **eDiscovery Roles** | `RoleManagement.Read.All` | 0.5 day | Low (few users) |

---

## Proposed Data Model

### New Fields on User Principal

```javascript
{
  // Existing fields...

  "e5FeatureUsage": {
    "reportDate": "2026-01-10",

    // Already available
    "hasPimAssignment": true,
    "hasIdentityProtectionRisk": false,

    // From new APIs
    "powerBiActivity": true,
    "pstnCallsMade": 12,
    "audioConferencingUsed": true,
    "isAccessReviewer": false,
    "defenderAlerts": 0,

    // Calculated
    "e5Score": 4,
    "e5Justification": ["PIM", "Power BI", "Audio Conferencing"],
    "recommendedLicense": "E5",  // or "E3", "E1"
    "potentialSavings": 0  // $0 if justified, $21 if E3, $47 if E1
  }
}
```

### E5 Justification Logic

```powershell
function Get-E5Justification {
    param($user)

    $justifications = @()
    $score = 0

    # Check each E5 feature
    if ($user.hasPimAssignment) {
        $justifications += "PIM"
        $score += 2
    }

    if ($user.powerBiActivity) {
        $justifications += "Power BI Pro"
        $score += 2
    }

    if ($user.pstnCallsMade -gt 0) {
        $justifications += "Phone System"
        $score += 2
    }

    if ($user.audioConferencingUsed) {
        $justifications += "Audio Conferencing"
        $score += 2
    }

    if ($user.isAccessReviewer) {
        $justifications += "Access Reviews"
        $score += 1
    }

    if ($user.defenderAlerts -gt 0) {
        $justifications += "Defender Protection"
        $score += 1
    }

    if ($user.hasIdentityProtectionRisk) {
        $justifications += "Identity Protection"
        $score += 1
    }

    # Recommendation
    $recommendation = switch ($score) {
        { $_ -ge 3 } { "E5" }
        { $_ -ge 1 } { "E3" }
        default { "E1" }
    }

    return @{
        Score = $score
        Justifications = $justifications
        Recommendation = $recommendation
    }
}
```

---

## Dashboard View

### License Optimization Table

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ LICENSE OPTIMIZATION                                           [Export CSV]  │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter: [Over-provisioned only ▼]                                            │
├──────────────────┬─────────┬──────────┬───────────────────────┬──────────────┤
│ User             │ Current │ Recommend│ E5 Features Used      │ Savings/mo   │
├──────────────────┼─────────┼──────────┼───────────────────────┼──────────────┤
│ john.doe@...     │ E5      │ E5       │ PIM, Power BI, Phone  │ $0           │
│ jane.smith@...   │ E5      │ E3       │ Basic Office only     │ $21          │
│ bob.wilson@...   │ E5      │ E1       │ Email only            │ $47          │
│ alice.jones@...  │ E5      │ E3       │ Access Reviews        │ $21          │
├──────────────────┴─────────┴──────────┴───────────────────────┴──────────────┤
│ Total E5 Users: 200 | Over-provisioned: 47 | Potential Savings: $1,692/month │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Justification Detail (Click to Expand)

```
┌─────────────────────────────────────────────────────────────────┐
│ jane.smith@contoso.com                                          │
├─────────────────────────────────────────────────────────────────┤
│ Current License: Microsoft 365 E5                               │
│ Recommended: Microsoft 365 E3                                   │
│ Monthly Savings: $21                                            │
├─────────────────────────────────────────────────────────────────┤
│ E5 Feature Usage Analysis:                                      │
│                                                                  │
│ ✗ PIM                    - No eligible role assignments         │
│ ✗ Power BI Pro           - No activity in 90 days               │
│ ✗ Phone System           - No PSTN calls                        │
│ ✗ Audio Conferencing     - No dial-in usage                     │
│ ✗ Access Reviews         - Not a reviewer                       │
│ ✗ eDiscovery             - No role assignment                   │
│ ✓ Identity Protection    - Evaluated (no risk detected)         │
│ ✓ Defender for Endpoint  - Device protected                     │
│                                                                  │
│ Conclusion: User benefits from security features but no         │
│ productivity E5 features. Consider E3 + Defender add-on.        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Complexity vs Value Matrix

| Detection Method | Complexity | Accuracy | Recommendation |
|-----------------|------------|----------|----------------|
| **PIM check** | ✅ Easy | High | **Do now** (already have data) |
| **Identity Protection** | ✅ Easy | Medium | **Do now** (already have data) |
| **Basic M365 usage** | ✅ Easy | Medium | **Phase 1** |
| **Power BI usage** | 🟡 Medium | High | **Phase 2** - clear E5 signal |
| **PSTN/Phone** | 🟡 Medium | High | **Phase 2** - clear E5 signal |
| **Access Reviews** | 🟡 Medium | Medium | Phase 2 |
| **Defender APIs** | 🔴 Hard | Medium | Phase 3 - complex integration |
| **eDiscovery roles** | 🟡 Medium | High | Phase 2 - few users affected |
| **Advanced Audit** | 🔴 Hard | Low | Defer - complex, low signal |

---

## Permissions Summary

### New Permissions Needed

| Permission | API | Required For |
|------------|-----|--------------|
| `Reports.Read.All` | Graph | M365 usage (from M365-usage.md) |
| `CallRecords.Read.All` | Graph | PSTN/Phone usage |
| `AccessReview.Read.All` | Graph | Access review participation |
| Power BI `Tenant.Read.All` | Power BI API | Power BI activity |

### Optional (Phase 3)

| Permission | API | Required For |
|------------|-----|--------------|
| `Machine.Read.All` | Defender API | Defender for Endpoint |
| `Alert.Read.All` | Defender API | Defender alerts |
| Management Activity API access | Office 365 | Defender for Office 365 |

---

## ROI Analysis

### Effort to Implement

| Phase | Effort | Features Detected |
|-------|--------|-------------------|
| Quick Win | 0 days | PIM, Identity Protection (already have) |
| Phase 1 | 3 days | + Basic M365 usage |
| Phase 2 | 3 days | + Power BI, PSTN, Access Reviews |
| Phase 3 | 5 days | + Defender, eDiscovery |
| **Total** | **11 days** | Full E5 usage detection |

### Expected Savings Detection

For a 1000-user organization with 200 E5 licenses:

| Detection Level | Over-provisioned Found | Annual Savings |
|-----------------|------------------------|----------------|
| Basic (Phase 1) | ~20% (40 users) | ~$10,000 |
| Advanced (Phase 2) | ~25% (50 users) | ~$12,600 |
| Complete (Phase 3) | ~30% (60 users) | ~$15,000 |

---

## Recommendations

### Immediate (0 effort)

Add to dashboard now using existing data:
- Flag E5 users with NO PIM assignments
- Flag E5 users with NO risk evaluation history
- These are candidates for review

### Short-term (Phase 1-2)

1. Implement basic M365 usage collection (M365-usage.md)
2. Add Power BI Admin API integration
3. Add PSTN usage detection
4. Build License Optimization view in dashboard

### Long-term (Phase 3)

1. Defender API integration
2. Advanced audit log analysis
3. Compliance role checking

---

## References

- [Microsoft 365 E5 Features](https://www.microsoft.com/en-us/microsoft-365/enterprise/e5)
- [Power BI REST API](https://learn.microsoft.com/en-us/rest/api/power-bi/)
- [Teams PSTN Usage Reports](https://learn.microsoft.com/en-us/graph/api/callrecords-callrecord-getpstncalls)
- [Access Reviews API](https://learn.microsoft.com/en-us/graph/api/resources/accessreviewsv2-overview)
- [Microsoft 365 Defender API](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/apis-intro)
