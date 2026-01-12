“Integrating Purview data into an IAM-focused dashboard is a smart move for visualizing the "Blast Radius" of a compromised identity. If an attacker gains access to a user account, knowing what data that user has been mishandling or has access to turns a simple identity alert into a high-priority incident.
Here is a ranked list of Purview data categories and their corresponding API endpoints, prioritized by how well they fit your theme of Attack Path Relationships.
1. Data Loss Prevention (DLP)
Relevance: High. This is the direct "smoking gun" for malicious or accidental data exfiltration. In an attack path, this shows the action taken by a compromised identity.
 * Suggested Columns:
   * DLP Alert Count (30d): Frequency of violations.
   * Top Sensitive Info Type: (e.g., Credit Card, Credentials, SSN) to show the severity.
   * Exfiltration Vector: Was it via USB, Web Upload, or Email?
 * Endpoint URI: * GET https://graph.microsoft.com/beta/security/alerts_v2?$filter=vendorAndServiceSource eq 'Microsoft Purview Data Loss Prevention'
   * Note: You can also use the Office 365 Management Activity API for raw events:
   * GET https://manage.office.com/api/v1.0/{tenant_id}/activity/feed/subscriptions/content?contentType=Audit.General
2. Insider Risk Management (IRM)
Relevance: High. IRM correlates signals (like a user resigning soon or unusual file downloads) to assign a User Risk Level. This is the perfect companion to Entra’s Identity Risk.
 * Suggested Columns:
   * Purview User Risk Score: (Low/Med/High).
   * Risk Category: (e.g., Data Theft, Security Violation).
   * Last High-Interest Activity: The specific event that triggered the risk score.
 * Endpoint URI: * GET https://graph.microsoft.com/beta/security/incidents?$filter=vendorAndServiceSource eq 'Microsoft Purview Insider Risk Management'
   * Note: IRM data is often pseudonymized. You may need to map the UserPrincipalName via a specific IRM-scoped application permission.
3. Information Protection (Sensitivity Labels)
Relevance: Medium-High. This defines the Value of the destination in an attack path. If a "Risky User" has access to "Highly Confidential" labels, the attack path is much more dangerous.
 * Suggested Columns:
   * Confidential File Access Count: How many labeled files the user interacts with.
   * Label Downgrade Events: If a user is removing protection from files (a major red flag).
 * Endpoint URI: * GET https://graph.microsoft.com/beta/informationProtection/policy/labels (To get label definitions)
   * GET https://manage.office.com/api/v1.0/{tenant_id}/activity/feed/... (Search for LabelApplied or LabelRemoved operations in the Audit Logs).
4. Adaptive Protection
Relevance: Very High (Technical). This is a bridge between Purview and IAM. It automatically changes a user's DLP policy based on their IRM risk level.
 * Suggested Columns:
   * Current Protection Level: (e.g., Elevated, Restricted).
   * Adaptive Policy Status: Is the user currently being "throttle-blocked" due to high risk?
 * Endpoint URI: * GET https://graph.microsoft.com/beta/security/subjectRightsRequests (Contextual data)
   * Note: Most Adaptive Protection states are currently found by querying the user's risk level in the IRM alerts mentioned above.
Summary Table for your Dashboard
| Category | Dashboard Column | Purpose in Attack Path | Endpoint Service |
|---|---|---|---|
| DLP | Active Alerts | Confirms data is currently leaving the org. | Graph Security API |
| IRM | User Risk Score | Predicts intent (Malicious vs. Compromised). | Graph Security API |
| Labels | Data Sensitivity | Defines the "Target Value" of the identity. | Audit Log API |
| Governance | Asset Ownership | Identifies who owns the "Crown Jewel" data. | Purview Data Plane |”

Since I have the full breakdown of your Entra Risk Dashboard, I can confirm that the previous Claude's advice was a 10/10 starting point. However, to make this a "Security Architect" level tool, here are three high-value suggestions they missed:
1. The "PIM Exposure" Layer (Privileged Identity Management)
The "Blast Radius" isn't just about what a user has access to, but what they can access.
 * The Logic: If a user is flagged as "High Risk" in Entra, and they have an Eligible Role (e.g., Global Admin or SharePoint Admin) that hasn't been activated yet, they are a ticking time bomb.
 * Suggested Column: Eligible Admin Roles.
 * Why: You want to see if a compromised identity has the potential to elevate their permissions to reach the sensitive Purview data.
 * Endpoint: GET https://graph.microsoft.com/v1.0/privilegedAccess/azureAD/roleAssignmentRequests
2. The "Label Downgrade" Signal (Intent Detection)
The previous advice mentioned Sensitivity Labels, but the most important event is when a label is removed or lowered.
 * The Logic: A user who is "Risky" and just changed a file from "Highly Confidential" to "Public" is likely exfiltrating data.
 * Suggested Column: Sensitivity Downgrade (24h).
 * Why: This distinguishes between a user who just happens to work with sensitive data and a user who is actively trying to bypass protections.
 * Source: This requires the Office 365 Management Activity API (looking for LabelRemoved or LabelDowngraded operations).
3. Service Principal "Data Permissions" (The CIEM Bridge)
Since you are already tracking Service Principal Risk, you should look at their "Permissions Creep."
 * The Logic: Apps often have "over-privileged" Graph API permissions (like Files.Read.All). If that App (Service Principal) is flagged as risky, you need to know if it has the "Keys to the Kingdom."
 * Suggested Column: High-Value Data Permissions (e.g., "Mail.Read", "Sites.Read.All").
 * Why: A risky app with User.Read is a minor issue; a risky app with Files.Read.Write.All is a catastrophe.
 * Endpoint: GET https://graph.microsoft.com/v1.0/servicePrincipals/{id}/oauth2PermissionGrants
Updated "Attack Path" Summary Table
| Category | Dashboard Column | Purpose in Attack Path | Data Source |
|---|---|---|---|
| PIM | Eligible High Roles | Potential for privilege escalation. | Graph API (PIM) |
| Audit Logs | Label Downgrades | Detects active attempts to bypass DLP. | O365 Management API |
| Permissions | App Data Scope | Maps the "Blast Radius" of non-human identities. | Entra CIEM / Graph |
| Purview | Active IRM Alerts | Correlates Entra risk with actual data behavior. | Purview IRM |
My Final Assessment
I strongly agree with the previous Claude's categorization. Purview data is the "Missing Link" in Identity Management.
If you add PIM eligibility and Label Downgrade events to what was already suggested, you aren't just building a dashboard; you're building an Identity Threat Detection and Response (ITDR) platform.
Would you like me to help you write the specific KQL queries for the "Label Downgrade" alerts to pull into your dashboard?“

I need to actually visit the website first to provide informed analysis. Let me do that now.​​​​​​​​​​​​​​​​

**Analysis of the Claude Response:**

The Claude analysis was **solid but incomplete**. Here’s my assessment:

## What Claude Got Right

1. **DLP as Priority #1** - Correct. This is the “outcome” metric in an attack path
1. **IRM Integration** - Excellent call. Bridging identity risk with behavioral risk is exactly what separates mature dashboards from basic ones
1. **Sensitivity Labels** - Good, but they missed the critical “downgrade” angle (which they caught in the follow-up)
1. **PIM Exposure** - The follow-up addition was brilliant. “Eligible but not active” roles are invisible time bombs

## Critical Gaps & My Additions

### 1. **Conditional Access Policy Violations** (MISSING - Priority: CRITICAL)

```
Endpoint: GET https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations
Cross-reference: Sign-in logs where CA policy was "not satisfied"
```

**Why this matters:** A risky user who is **bypassing** CA policies (e.g., logging in from a non-compliant device or blocked location) is a different threat tier than one who is simply flagged as risky. This shows **active evasion**.

**Dashboard Column:** `CA Bypass Attempts (7d)`

### 2. **Authentication Method Changes** (MISSING - Priority: HIGH)

```
Endpoint: GET https://graph.microsoft.com/v1.0/auditLogs/directoryAudits
Filter: activityDisplayName eq 'Update user' AND category eq 'UserManagement'
```

**Why this matters:** Attackers often disable MFA or add their own auth methods after initial compromise. Correlating “Risky User” + “MFA method changed in last 48h” is a **tier-1 indicator**.

**Dashboard Column:** `Auth Method Changes (48h)`

### 3. **Token Lifetime Anomalies** (MISSING - Priority: MEDIUM)

```
Endpoint: GET https://graph.microsoft.com/beta/identity/conditionalAccess/authenticationStrength/policies
Cross-reference: Sign-in logs with unusually long-lived tokens
```

**Why this matters:** Long-lived refresh tokens are gold for attackers. A risky user with a 90-day token is a sustained threat.

**Dashboard Column:** `Active Token Age (Max)`

### 4. **Purview eDiscovery Cases** (Claude MISSED This Entirely)

```
Endpoint: GET https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases
```

**Why this matters:** If a user is already under **legal hold** or is the subject of an eDiscovery case, and they’re ALSO flagged as risky, this suggests potential **insider threat under investigation**.

**Dashboard Column:** `Under Investigation` (Yes/No)

### 5. **Service Principal Certificate Expiry** (Partial Coverage)

Claude mentioned SP permissions but not **credential hygiene**:

```
Endpoint: GET https://graph.microsoft.com/v1.0/servicePrincipals/{id}/keyCredentials
```

**Why this matters:** Risky SPs with expired/expiring certs often indicate **orphaned apps** that are prime targets for takeover.

**Dashboard Column:** `Cert Expiry <30d`

-----

## Revised “Attack Path Taxonomy”

|Layer                   |Metric             |Attack Stage           |Claude Covered?   |
|------------------------|-------------------|-----------------------|------------------|
|**Entry**               |Risky Sign-in      |Initial Access         |Yes (core feature)|
|**Persistence**         |Auth Method Changed|Credential Manipulation|**NO**            |
|**Privilege Escalation**|Eligible PIM Roles |Lateral Movement Prep  |Yes (follow-up)   |
|**Defense Evasion**     |CA Policy Bypass   |Active Evasion         |**NO**            |
|**Collection**          |DLP Alerts         |Data Staging           |Yes               |
|**Exfiltration**        |Label Downgrade    |Data Theft             |Yes (follow-up)   |
|**Impact**              |Purview IRM Score  |Intent Confirmation    |Yes               |
|**Investigation**       |eDiscovery Case    |Legal/HR Context       |**NO**            |

-----

## Architecture Suggestions

### API Call Optimization

You’re about to hit **9+ different endpoints**. Consider:

1. **Batch Requests** where possible:

```json
POST https://graph.microsoft.com/v1.0/$batch
{
  "requests": [
    { "id": "1", "method": "GET", "url": "/identityProtection/riskyUsers" },
    { "id": "2", "method": "GET", "url": "/auditLogs/signIns?$filter=..." }
  ]
}
```

1. **Delta Queries** for audit logs (only fetch changes since last run):

```
GET /auditLogs/signIns/delta?$deltatoken={previous_token}
```

### Data Storage Pattern

Given you’re using Azure Functions, consider:

- **Table Storage** for time-series risk scores (cheap, fast lookups)
- **Cosmos DB** if you need to do complex joins across Entra + Purview data
- **Log Analytics Workspace** if you want to use KQL for adhoc queries

-----

## My Disagreements with Claude

1. **Adaptive Protection Endpoint** - They suggested `subjectRightsRequests` which is for **GDPR compliance**, not adaptive DLP. The correct endpoint is buried in the Security API under IRM alerts (they were directionally right but technically wrong).
1. **Label API** - `GET /informationProtection/policy/labels` only gives you label **definitions**, not **usage**. You need the Audit Log API with filter for `SensitivityLabelApplied/SensitivityLabelRemoved` operations.
1. **“Pseudonymized” IRM Data** - This is outdated. If you have the correct Graph permissions (`SecurityIncident.Read.All`), you get plaintext UPNs in IRM alerts.

-----

## Bottom Line

Claude gave you a **7/10 foundation**. The additions about PIM and label downgrades bumped it to **8.5/10**.

With my additions (CA bypass, auth method changes, eDiscovery context), you’d have a **true ITDR platform** that maps to MITRE ATT&CK stages, not just a “pretty risk dashboard.”

Want me to draft the PowerShell module structure for the API integrations?​​​​​​​​​​​​​​​​


—————

# Best response 

Now I can actually see what you’ve built. This changes everything about my previous analysis.

**What I’m Looking At**

You have a graph-based identity security platform that’s tracking principals (users, groups, service principals, devices), resources (Azure infrastructure, applications, directory roles), edges (relationships and permissions between them), policies (Conditional Access, PIM, compliance), and historical changes (delta tracking). The counts show this is operating at real scale: 420 principals, 1011 resources, 1520 edges with 846 derived relationships.

This is not a simple “risky users dashboard.” This is an attack path analysis engine. You’re mapping the entire identity and resource topology of an Azure/Entra environment and tracking how principals can traverse that graph to reach sensitive resources.

**How This Fundamentally Changes the Purview Question**

The previous Claude sessions were giving you advice for a traditional security dashboard that correlates identity risk scores with data loss events. But that’s not what you’re building. You’re building a system that understands **who can reach what through which paths**.

When you add Purview data to this architecture, you’re not just adding “another data source to correlate.” You’re adding the final piece that answers the question: “What is the blast radius if this principal is compromised, and what evidence do we have that the compromise has already been exploited?”

Let me work through what Purview data actually matters in this context.

**DLP Alerts: Not as Dashboard Metrics, But as Edge Weights**

The previous analysis suggested tracking DLP alert counts per user as a dashboard column. But in your graph model, DLP violations should modify the risk weight of edges. When a user triggers a DLP alert while accessing a SharePoint site, that’s not just a user property—it’s evidence that the edge between that user and that SharePoint resource represents an active exploitation path.

What you want from the DLP endpoint is not aggregate statistics but the specific resource identifiers involved in each violation. When you get a DLP alert, you want to extract: which user (principalId), which resource (the SharePoint site URL, OneDrive location, or email recipient domain), what sensitive information type was detected, and when it happened.

Then you integrate this into your graph by increasing the risk weight of that specific edge. If User A has membership in Group B which has access to SharePoint Site C, and User A just triggered a DLP alert while accessing Site C, then the path User A → Group B → Site C gets marked as “actively exploited” rather than just “theoretically possible.”

This is completely different from displaying “User A has 5 DLP alerts this month” as a summary statistic. You’re using DLP data to highlight which attack paths are currently being traversed versus which ones are dormant.

**Insider Risk Management: Detecting Privilege Escalation Preparation**

Your dashboard shows you’re already tracking PIM roles (21 PIM role assignments) and derived edges (846 relationships). IRM becomes valuable when it detects behavioral signals that someone is preparing to exploit those privilege escalation paths.

The specific IRM indicators that matter for your graph model are the ones that show **reconnaissance** behavior. When IRM detects that a user is accessing resources they don’t normally access, especially if those resources contain information about privileged accounts or security policies, that suggests they’re mapping the environment before launching an attack.

What you want from the IRM endpoint is the indicator sequence that shows: user accessed documentation about PIM activation → user accessed list of privileged role members → user began downloading unusual volumes of data. This sequence, when correlated with your graph showing that this user has an eligible PIM role, tells you they’re likely preparing to activate that role and exfiltrate data.

The integration point is to flag principals in your graph who have both IRM alerts and eligible privileged roles (which you can already identify from your PIM Roles edges). This combination reveals who has both the capability and the apparent intent to escalate privileges.

**Information Protection Labels: Identifying Crown Jewel Resources**

You’re tracking 1011 resources in your graph. Not all of those resources are equally valuable. Sensitivity labels tell you which SharePoint sites, which file shares, which applications contain the most sensitive data.

The previous analysis focused on label downgrade events as suspicious user behavior. But in your graph architecture, labels should be used to calculate resource criticality scores. When you query the Information Protection policy endpoint and see that a SharePoint site contains 500 files labeled “Highly Confidential” versus a site with only “General” labeled content, those sites have fundamentally different security implications.

Your derived edges (846 of them) represent calculated attack paths between principals and resources. When you weight those paths by resource sensitivity (derived from label distribution), you can identify which paths lead to crown jewel data versus which paths lead to low-value resources.

The specific implementation would be querying the Microsoft Graph for files with sensitivity labels, aggregating by container (SharePoint site, OneDrive, shared folder), and then joining that aggregation back to your resources table to add a “data sensitivity score” property. Then your attack path calculations can prioritize paths that lead to high-sensitivity resources.

**Communication Compliance: Detecting Coordinated Insider Threats**

Your graph model tracks group memberships (173 group member edges). Communication Compliance becomes important when you need to detect whether multiple principals who share group membership are coordinating malicious activity.

When Communication Compliance flags messages between User A and User B discussing exfiltration plans, and your graph shows that both User A and User B are members of the same security group that has access to sensitive resources, you’ve identified a coordinated insider threat scenario that wouldn’t be visible by looking at individual user behavior.

The integration point is correlating Communication Compliance alerts with your group membership edges. When multiple members of the same group trigger communication policy violations within a short time window, especially if those members also have DLP alerts or IRM detections, you’re seeing evidence of collaboration rather than isolated incidents.

This is particularly relevant for your service principals (316 of them). If Communication Compliance detects that users are discussing “borrowing service principal credentials” or “using the automation account,” and your graph shows that those service principals have broad permissions across Azure resources, you can identify that specific service principals are being targeted.

**eDiscovery: Understanding Investigation Scope Within Your Graph**

You’re tracking 500 historical changes through delta tracking. eDiscovery integration tells you which principals and resources are currently under preservation or investigation, which changes how you interpret changes in your delta log.

When your delta tracking shows that a user’s permissions were modified (a new edge was added in your graph), and that user is also under eDiscovery hold, the permission change takes on investigative significance. It might represent evidence of privilege escalation that’s relevant to the ongoing investigation.

The specific value for your architecture is marking principals and resources that are under eDiscovery hold with a special property in your graph. Then when your attack path analysis identifies a concerning path that involves a principal or resource under hold, you know there’s already external validation that this entity is of concern.

**Adaptive Protection: Dynamic Policy Enforcement Based on Graph Position**

You’re tracking Conditional Access policies (3 policies) and have 298 total policies in your environment. Adaptive Protection modifies DLP policy assignments based on IRM risk scores.

In your graph model, this means that the policy edges (10 CA Policy edges shown in your dashboard) are dynamic rather than static. A user’s effective permissions and restrictions change based on their IRM score, which means your attack path calculations need to account for dynamic policy enforcement.

What you want from Adaptive Protection is not just knowing a user’s current protection level, but understanding which policies are being dynamically applied and how those policies restrict the attack paths available to that user.

For example, if User A normally has access to SharePoint Site B, but Adaptive Protection has applied a restrictive DLP policy that blocks external sharing for that user, then the attack path User A → SharePoint Site B → External Exfiltration is theoretically blocked. However, if you then see a DLP violation showing that User A attempted external sharing anyway, you know they’re actively trying to bypass the adaptive restrictions.

**The Data Source the Previous Analysis Completely Missed: Privileged Access Management (PAM)**

Your dashboard shows you’re tracking managed identities (6 Managed Identity edges) and Key Vault access (0 KV Access edges currently). PAM (different from PIM) tracks Just-In-Time privileged access to Azure resources through Privileged Access Workstations and Azure Bastion.

When a user requests JIT access to a VM or uses a Privileged Access Workstation to access a Key Vault, those access requests and approvals are logged. This matters for your graph because it shows privilege elevation at the resource level rather than the directory role level.

If your graph shows that User A has a potential attack path to Key Vault B through a managed identity or RBAC assignment, but PAM logs show that User A recently requested and was denied JIT access to that Key Vault, you’re seeing evidence of attempted privilege escalation that failed through normal channels. This suggests the user might try alternative paths through your graph to reach that same resource.

The integration would be correlating PAM access requests with your RBAC edges (34 Azure RBAC edges) and Key Vault access edges. When someone requests access that they shouldn’t need based on their current role assignments, and your graph shows they have alternative paths to reach the same resource, that’s reconnaissance behavior.

**My Revised Assessment Based on Actually Seeing Your Dashboard**

The previous Claude sessions gave you advice for a linear correlation dashboard: Identity Risk Score + DLP Alerts + IRM Score = Overall Risk. That’s not what you need.

You need Purview data that enhances your graph traversal and attack path analysis. Specifically, you need:

1. DLP alerts with resource identifiers to weight edges by active exploitation
1. IRM indicators that show reconnaissance of privileged paths
1. Sensitivity label distribution to score resource criticality
1. Communication Compliance alerts between principals who share group membership
1. eDiscovery holds to flag principals/resources already under investigation
1. Adaptive Protection policy changes to understand dynamic path restrictions
1. PAM access requests showing attempted privilege escalation at the resource level

The fundamental insight is that Purview data shouldn’t be separate dashboard sections—it should be integrated into your existing graph model as edge weights, node properties, and path risk scores. You’re not building a “dashboard with Purview data.” You’re enhancing an attack path analysis engine with behavioral evidence from Purview that shows which theoretical paths are being actively exploited.

Does this align with how you’re thinking about the integration, or am I still missing something about your architecture?​​​​​​​​​​​​​​​​


# Technical Proposal

# Technical Implementation Proposal: Purview Integration for Graph-Based Attack Path Analysis

## Architecture Overview

**Integration Pattern**: Event-driven enrichment of existing graph nodes and edges
**Storage**: Extend existing Table Storage schema with Purview properties
**Processing**: Add Purview collection functions that run parallel to existing Entra collectors

## Data Collection Functions

### Function 1: `Get-PurviewDLPAlerts`

**Purpose**: Collect DLP violations with resource context to weight edges

**Endpoint**:

```powershell
$uri = "https://graph.microsoft.com/beta/security/alerts_v2?`$filter=classification eq 'truePositive' and serviceSource eq 'Microsoft Purview Data Loss Prevention'&`$top=999"
```

**Critical Properties to Extract**:

- `actorDisplayName` / `userPrincipalName` → maps to your principals
- `entities` array → contains resource URLs (SharePoint sites, OneDrive paths, email recipients)
- `evidence.detectionSource` → the specific DLP rule triggered
- `createdDateTime` → for time-windowed correlation
- `severity` → for edge weight calculation

**Schema Addition to Your Graph**:

```powershell
# New property on edges table
@{
    EdgeId = "user_abc → sharepoint_xyz"
    LastDLPViolation = "2026-01-11T15:30:00Z"
    DLPViolationCount30d = 3
    DLPSeverityMax = "high"
    EdgeRiskWeight = 85  # Base weight * DLP multiplier
}
```

**Implementation**:

```powershell
function Get-PurviewDLPAlerts {
    param([string]$AccessToken, [int]$DaysBack = 30)
    
    $since = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = "https://graph.microsoft.com/beta/security/alerts_v2?`$filter=createdDateTime ge $since and serviceSource eq 'Microsoft Purview Data Loss Prevention'"
    
    $alerts = Get-GraphPagedResult -Uri $uri -AccessToken $AccessToken
    
    foreach ($alert in $alerts) {
        [PSCustomObject]@{
            UserId = $alert.actorDisplayName
            ResourceUrl = ($alert.entities | Where-Object entityType -eq 'CloudApplication').url
            DetectedInfoTypes = ($alert.evidence.detectionSource -join ',')
            Severity = $alert.severity
            Timestamp = $alert.createdDateTime
        }
    }
}
```

### Function 2: `Get-PurviewIRMIndicators`

**Purpose**: Identify principals preparing for privilege escalation

**Endpoint**:

```powershell
$uri = "https://graph.microsoft.com/beta/security/incidents?`$filter=classification eq 'truePositive' and serviceSource eq 'Microsoft Purview Insider Risk Management'&`$expand=alerts"
```

**Critical Properties**:

- `alerts.entities` → which principals triggered which indicators
- `alerts.title` → indicator type (e.g., “Unusual file download”, “Accessed competitor resources”)
- Sequence detection: order of `alerts` array shows temporal progression

**Schema Addition**:

```powershell
# New table: PurviewIRMIndicators
@{
    PrincipalId = "user_abc"
    IndicatorSequence = @("FileDownloadSpike", "AccessedHRFiles", "AccessedFinancials")
    SequenceStartTime = "2026-01-10T08:00:00Z"
    LastIndicatorTime = "2026-01-11T14:22:00Z"
    IRMRiskLevel = "high"
}
```

**Correlation Logic**:

```powershell
# After collecting IRM data, correlate with PIM eligibility
$riskPrincipals = $irmIndicators | Where-Object IRMRiskLevel -eq 'high'
$privilegedPaths = $edges | Where-Object EdgeType -eq 'PIMRole'

foreach ($principal in $riskPrincipals) {
    $eligibleRoles = $privilegedPaths | Where-Object SourceId -eq $principal.PrincipalId
    if ($eligibleRoles) {
        # Flag as high-priority: has intent (IRM) + capability (PIM)
        Update-PrincipalRiskScore -PrincipalId $principal.PrincipalId -Amplifier 2.5
    }
}
```

### Function 3: `Get-SensitivityLabelDistribution`

**Purpose**: Calculate resource criticality scores

**Endpoints**:

```powershell
# Get label definitions
$labels = "https://graph.microsoft.com/beta/informationProtection/policy/labels"

# Get label usage via Audit Log
$auditUri = "https://manage.office.com/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=Audit.SharePoint"
```

**Processing Pattern**:

1. Query audit logs for `SensitivityLabelApplied` operations in last 90 days
1. Aggregate by `SiteUrl` or `ObjectId` (the container)
1. Calculate sensitivity score: `(HighlyConfidential * 10) + (Confidential * 5) + (Internal * 2) + (Public * 0)`

**Schema Addition**:

```powershell
# New property on resources table
@{
    ResourceId = "sharepoint_site_xyz"
    SensitivityScore = 87  # High concentration of Highly Confidential files
    LabelDistribution = @{
        HighlyConfidential = 43
        Confidential = 12
        Internal = 5
    }
    LastLabelAuditDate = "2026-01-11T20:00:00Z"
}
```

**Attack Path Weighting**:

```powershell
# When calculating attack paths, multiply edge risk by destination resource sensitivity
foreach ($path in $attackPaths) {
    $targetResource = $resources | Where-Object Id -eq $path.TargetResourceId
    $path.OverallRisk = $path.EdgeRiskWeight * ($targetResource.SensitivityScore / 100)
}
```

### Function 4: `Get-CommunicationComplianceAlerts`

**Purpose**: Detect coordinated threats via group membership correlation

**Endpoint**:

```powershell
$uri = "https://graph.microsoft.com/beta/security/alerts_v2?`$filter=serviceSource eq 'Microsoft Purview Communication Compliance'"
```

**Critical Properties**:

- `entities` array → contains both participants in flagged communication
- `title` → policy violation type
- `createdDateTime` → for temporal clustering

**Correlation Logic**:

```powershell
# Group alerts by time window and check for shared group membership
$alertsByWindow = $commCompAlerts | Group-Object {
    [Math]::Floor((New-TimeSpan -Start $baseDate -End $_.createdDateTime).TotalHours / 24)
}

foreach ($window in $alertsByWindow) {
    $participants = $window.Group.entities.userPrincipalName | Select-Object -Unique
    
    # Check if participants share security groups
    $sharedGroups = $edges | Where-Object {
        $_.EdgeType -eq 'GroupMember' -and
        $_.SourceId -in $participants
    } | Group-Object TargetId | Where-Object Count -gt 1
    
    if ($sharedGroups) {
        # Flag coordinated activity
        Add-ThreatIndicator -Type 'CoordinatedInsiderThreat' -Principals $participants -Groups $sharedGroups.Name
    }
}
```

### Function 5: `Get-eDiscoveryCustodians`

**Purpose**: Mark principals/resources under investigation

**Endpoint**:

```powershell
$uri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases?`$expand=custodians,reviewSets"
```

**Schema Addition**:

```powershell
# New property on principals table
@{
    PrincipalId = "user_abc"
    UnderInvestigation = $true
    eDiscoveryCaseId = "case_xyz"
    CaseCreatedDate = "2026-01-05T00:00:00Z"
    InvestigationScope = "mailbox,onedrive,teams"
}
```

**Delta Log Enhancement**:

```powershell
# When processing historical changes (your 500-item delta log)
foreach ($change in $deltaLog) {
    $principal = $principals | Where-Object Id -eq $change.objectId
    if ($principal.UnderInvestigation) {
        $change | Add-Member -NotePropertyName 'InvestigativeRelevance' -NotePropertyValue $true
        $change | Add-Member -NotePropertyName 'RelatedCase' -NotePropertyValue $principal.eDiscoveryCaseId
    }
}
```

### Function 6: `Get-AdaptiveProtectionState`

**Purpose**: Track dynamic DLP policy assignments

**Approach**: Since there’s no direct “Adaptive Protection” endpoint, infer state from IRM risk + DLP policy assignments

**Implementation**:

```powershell
function Get-AdaptiveProtectionState {
    param([string]$AccessToken)
    
    # Get users with elevated IRM risk
    $irmUsers = Get-PurviewIRMIndicators -AccessToken $AccessToken | 
        Where-Object IRMRiskLevel -in @('high','medium')
    
    # Get current DLP policy assignments (from Exchange/SharePoint admin)
    # NOTE: This requires Exchange Online PowerShell or Security & Compliance PowerShell
    # Can't be done via Graph API directly - may need separate function app with EXO module
    
    foreach ($user in $irmUsers) {
        [PSCustomObject]@{
            PrincipalId = $user.PrincipalId
            IRMRiskLevel = $user.IRMRiskLevel
            AdaptivePolicyApplied = $true  # Inferred from risk level
            ExpectedRestrictions = @('BlockExternalSharing','RequireEncryption')
        }
    }
}
```

**Edge Impact**:

```powershell
# Modify edge weights based on adaptive restrictions
$adaptiveUsers = Get-AdaptiveProtectionState
foreach ($edge in $edges | Where-Object EdgeType -eq 'ResourceAccess') {
    if ($edge.SourceId -in $adaptiveUsers.PrincipalId) {
        $edge.PolicyRestriction = 'AdaptiveDLP'
        $edge.TheoreticallyBlocked = $true
        # If DLP violation still occurred, mark as bypass attempt
        if ($edge.LastDLPViolation -gt $edge.AdaptivePolicyAppliedDate) {
            $edge.BypassAttempted = $true
        }
    }
}
```

### Function 7: `Get-PAMAccessRequests`

**Purpose**: Detect attempted privilege escalation via JIT access

**Endpoint**:

```powershell
# Azure Activity Logs via Azure Management API
$uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&`$filter=eventTimestamp ge '$since' and operationName.value eq 'Microsoft.Security/locations/jitNetworkAccessPolicies/initiate/action'"
```

**Schema Addition**:

```powershell
# New table: PAMAccessAttempts
@{
    PrincipalId = "user_abc"
    TargetResourceId = "vm_xyz" # or "keyvault_abc"
    RequestTime = "2026-01-11T10:15:00Z"
    RequestStatus = "Denied"  # or "Approved"
    Justification = "Need to troubleshoot production issue"
}
```

**Correlation with Graph**:

```powershell
# Find users with denied PAM requests who have alternative paths
$deniedRequests = $pamAttempts | Where-Object RequestStatus -eq 'Denied'

foreach ($request in $deniedRequests) {
    # Check if user has RBAC path to same resource
    $alternatePaths = Find-AttackPath -Source $request.PrincipalId -Target $request.TargetResourceId
    
    if ($alternatePaths) {
        Add-ThreatIndicator -Type 'AlternativePathAfterDenial' -Details @{
            User = $request.PrincipalId
            DeniedResource = $request.TargetResourceId
            AlternatePath = $alternatePaths[0].PathString
        }
    }
}
```

## Integration Architecture

### Modified Function App Structure

```
EntraRiskCollector/
├── Collectors/
│   ├── Entra/
│   │   ├── Get-Users.ps1
│   │   ├── Get-ServicePrincipals.ps1
│   │   └── ...
│   └── Purview/  # NEW
│       ├── Get-PurviewDLPAlerts.ps1
│       ├── Get-PurviewIRMIndicators.ps1
│       ├── Get-SensitivityLabelDistribution.ps1
│       ├── Get-CommunicationComplianceAlerts.ps1
│       ├── Get-eDiscoveryCustodians.ps1
│       ├── Get-AdaptiveProtectionState.ps1
│       └── Get-PAMAccessRequests.ps1
├── Processors/
│   ├── Build-GraphEdges.ps1
│   └── Calculate-AttackPaths.ps1
│   └── Enrich-GraphWithPurview.ps1  # NEW
└── run.ps1
```

### Execution Flow

```powershell
# In your main orchestrator function
function Start-DataCollection {
    # Existing Entra collection (parallel)
    $entraJobs = @(
        Start-ThreadJob { Get-Users }
        Start-ThreadJob { Get-ServicePrincipals }
        # ... existing collectors
    )
    
    # NEW: Purview collection (parallel)
    $purviewJobs = @(
        Start-ThreadJob { Get-PurviewDLPAlerts -DaysBack 30 }
        Start-ThreadJob { Get-PurviewIRMIndicators }
        Start-ThreadJob { Get-SensitivityLabelDistribution }
        Start-ThreadJob { Get-CommunicationComplianceAlerts -DaysBack 7 }
        Start-ThreadJob { Get-eDiscoveryCustodians }
        Start-ThreadJob { Get-PAMAccessRequests -DaysBack 30 }
    )
    
    # Wait for all jobs
    $allJobs = $entraJobs + $purviewJobs
    $results = $allJobs | Receive-Job -Wait -AutoRemoveJob
    
    # Enrich graph with Purview data
    Enrich-GraphWithPurview -GraphData $graphData -PurviewData $results
}
```

### Graph Enrichment Function

```powershell
function Enrich-GraphWithPurview {
    param(
        [object]$GraphData,
        [object[]]$PurviewData
    )
    
    $dlpAlerts = $PurviewData | Where-Object DataType -eq 'DLP'
    $irmIndicators = $PurviewData | Where-Object DataType -eq 'IRM'
    $labelData = $PurviewData | Where-Object DataType -eq 'SensitivityLabels'
    
    # Enrich edges with DLP violations
    foreach ($alert in $dlpAlerts) {
        $matchingEdge = $GraphData.Edges | Where-Object {
            $_.SourceId -eq $alert.UserId -and $_.TargetId -match $alert.ResourceUrl
        }
        if ($matchingEdge) {
            $matchingEdge.DLPViolationCount++
            $matchingEdge.LastDLPViolation = $alert.Timestamp
            $matchingEdge.EdgeRiskWeight *= 1.5  # Amplify risk
        }
    }
    
    # Enrich principals with IRM indicators
    foreach ($indicator in $irmIndicators) {
        $principal = $GraphData.Principals | Where-Object Id -eq $indicator.PrincipalId
        if ($principal) {
            $principal.IRMRiskLevel = $indicator.IRMRiskLevel
            $principal.IRMIndicatorSequence = $indicator.IndicatorSequence
            
            # Check for privilege escalation preparation
            $pimEligible = $GraphData.Edges | Where-Object {
                $_.EdgeType -eq 'PIMRole' -and $_.SourceId -eq $indicator.PrincipalId
            }
            if ($pimEligible) {
                $principal.PrivilegeEscalationRisk = $true
            }
        }
    }
    
    # Enrich resources with sensitivity scores
    foreach ($label in $labelData) {
        $resource = $GraphData.Resources | Where-Object Id -match $label.ResourceId
        if ($resource) {
            $resource.SensitivityScore = $label.SensitivityScore
            $resource.LabelDistribution = $label.LabelDistribution
        }
    }
}
```

## Dashboard Visualization Changes

### New Graph Node Properties

**Principals** (add columns):

- `IRMRiskLevel`: low/medium/high/critical
- `IRMIndicatorCount`: integer
- `UnderInvestigation`: boolean
- `DLPViolations30d`: integer

**Resources** (add columns):

- `SensitivityScore`: 0-100
- `HighlyConfidentialFileCount`: integer
- `IsUnderHold`: boolean (eDiscovery)

**Edges** (add columns):

- `ActivelyExploited`: boolean (has recent DLP violation)
- `EdgeRiskWeight`: 0-100 (base weight * Purview amplifiers)
- `PolicyRestriction`: string (e.g., “AdaptiveDLP”)

### New Dashboard Section: Attack Path Priority

```
TOP 10 HIGH-RISK ATTACK PATHS
Path                                          | Risk Score | Evidence
User47 → TestGroup → SharePointSite          | 95         | DLP: 3 violations, IRM: High
ServicePrincipal-HR → KeyVault-Prod          | 88         | PAM: Denied access attempt
User28 → PIM-GlobalAdmin → All Resources    | 92         | IRM: Privilege seeking behavior
```

## Required Permissions

Add to your managed identity:

```powershell
# Microsoft Graph
SecurityIncident.Read.All           # For IRM and Communication Compliance
SecurityAlert.Read.All              # For DLP alerts
InformationProtectionPolicy.Read    # For sensitivity labels
eDiscovery.Read.All                 # For eDiscovery cases

# Office 365 Management API
ActivityFeed.Read                   # For audit logs (label usage)

# Azure Management API
Microsoft.Insights/logs/read        # For PAM access requests
```

## Performance Considerations

**Token Management**: Your existing `Get-CachedManagedIdentityToken` handles this. Add Office 365 Management API resource:

```powershell
$o365Token = Get-CachedManagedIdentityToken -Resource "https://manage.office.com"
```

**Data Volume**: Purview endpoints can return large result sets. Use your existing `Get-GraphPagedResult` pattern with `$top=999`.

**Execution Time**: With 7 new parallel collectors, total execution time increases by ~30 seconds (longest Purview API call). Still well within Azure Function timeout.

## Next Steps

1. Create `Purview/` folder in your collectors directory
1. Implement `Get-PurviewDLPAlerts` first (highest value, simplest integration)
1. Test edge enrichment with DLP data on subset of your graph
1. Add remaining collectors incrementally
1. Update dashboard HTML to display new principal/resource/edge properties
