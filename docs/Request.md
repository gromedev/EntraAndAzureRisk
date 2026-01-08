# Privilege Request: Entra Risk Analysis Platform V3.5

**Project:** Entra Risk Analysis - Identity & Azure Security Monitoring
**Version:** 3.5
**Requestor:** [Your Name/Team]
**Date:** 2026-01-08
**Purpose:** Deploy automated security monitoring for Entra ID and Azure infrastructure

---

## Executive Summary

This request covers the minimum privileges required to deploy and operate an automated security monitoring platform that:
- Collects Entra ID and Azure configuration data (read-only)
- Identifies attack paths, privilege escalation risks, and policy gaps
- Provides audit trails and compliance reporting

**No modifications are made to production systems** - all access is read-only except for writing to dedicated monitoring resources.

---

## 1. Azure Subscription Permissions

### Required Role: Contributor (scoped to specific resource group)

| Resource Type | Why Needed | What For |
|---------------|------------|----------|
| **Resource Group** | Container for all monitoring resources | Create `rg-entrarisk-v3-001` to isolate solution resources |
| **Storage Account** | Landing zone for collected data | Store raw security data (auto-deleted after 7-90 days) |
| **Cosmos DB Account** | Security data warehouse | Store processed identity/resource/relationship data with delta detection |
| **Function App** | Data collection orchestration | Run 12 collectors + 5 indexers (PowerShell, serverless) |
| **App Service Plan** | Function App compute | Consumption plan (Dynamic) - pay per execution |
| **Key Vault** | Secrets management | Store connection strings and credentials (if needed) |
| **Log Analytics** | Monitoring logs | Track collection runs, errors, and audit operations |
| **Application Insights** | Telemetry | Monitor function execution and troubleshooting |

**Alternative:** If Contributor at RG scope is not acceptable, grant these specific roles:
- `Storage Blob Data Contributor` (storage account)
- `DocumentDB Account Contributor` (Cosmos DB)
- `Website Contributor` (Function App)
- `Key Vault Administrator` (Key Vault)
- `Log Analytics Contributor` (workspace)

### Azure RBAC Assignments (Managed Identity)

The Function App's system-assigned managed identity requires these Azure roles:

| Role | Scope | Why Needed | What For |
|------|-------|------------|----------|
| **Storage Blob Data Contributor** | Storage Account | Write collected data | Upload security data to blob storage (JSONL format) |
| **Cosmos DB Data Contributor** (*Custom*) | Cosmos DB Account | Write processed data, **NO delete** | Index security data; custom role prevents deletion of audit records |
| **Key Vault Secrets User** | Key Vault | Read secrets | Access connection strings if stored in KV |

**Security Note:** The custom Cosmos DB role explicitly **excludes** delete permissions on audit containers to ensure tamper-proof audit trails.

---

## 2. Microsoft Graph API Permissions (Entra ID)

### Required: Application Permissions (14 permissions)

All permissions are **read-only** and assigned to the Function App's managed identity.

| Permission | Scope | Why Needed | What For |
|------------|-------|------------|----------|
| **User.Read.All** | All users | Collect user accounts | Monitor user lifecycle, MFA status, sign-in activity, risk levels |
| **Group.Read.All** | All groups | Collect group memberships | Track privilege assignments via groups, nested memberships |
| **Application.Read.All** | All apps | Collect app registrations | Monitor app permissions, federated credentials, API access |
| **Directory.Read.All** | Directory objects | General directory access | Read directory roles, organization info, tenant config |
| **Device.Read.All** | All devices | Collect device inventory | Monitor device compliance, Intune enrollment, OS versions |
| **AuditLog.Read.All** | Audit logs | Collect sign-in/audit events | Security event correlation, anomaly detection (90-day retention) |
| **Policy.Read.All** | All policies | Collect CA policies | Analyze Conditional Access coverage, MFA enforcement gaps |
| **RoleManagement.Read.All** | Role assignments | Collect directory role assignments | Track privileged access, PIM eligibility, role activations |
| **IdentityRiskEvent.Read.All** | Risk detections | Collect Identity Protection events | Monitor risk detections, risky sign-ins |
| **IdentityRiskyUser.Read.All** | Risky users | Collect user risk states | Track users flagged by Identity Protection (requires P2 license) |
| **UserAuthenticationMethod.Read.All** | Auth methods | Collect MFA registration | Identify users without MFA, passwordless adoption |
| **PrivilegedAccess.Read.AzureAD** | PIM for directory roles | Collect PIM eligibility | Monitor eligible directory role assignments |
| **PrivilegedAccess.Read.AzureADGroup** | PIM for groups | Collect PIM group eligibility | Monitor PIM-enabled group memberships |
| **PrivilegedAccess.Read.AzureResources** | PIM for Azure | Collect Azure PIM eligibility | Monitor eligible Azure role assignments |

**Security Notes:**
- All permissions are **application-level (non-delegated)** - no user context required
- All permissions are **read-only** - no write/modify/delete capabilities
- Permissions are assigned to a **managed identity** (not a user account)
- No consent bypass - requires admin consent approval

### Permission Justification by Use Case

| Use Case | Required Permissions | Business Value |
|----------|---------------------|----------------|
| **MFA Coverage Analysis** | User.Read.All, UserAuthenticationMethod.Read.All, Policy.Read.All | Identify users without MFA; validate Conditional Access coverage |
| **Privilege Escalation Detection** | RoleManagement.Read.All, Group.Read.All, PrivilegedAccess.Read.* | Map attack paths to Global Admin; detect shadow admins |
| **Identity Risk Monitoring** | IdentityRiskEvent.Read.All, IdentityRiskyUser.Read.All, AuditLog.Read.All | Correlate risky users with audit events; track risk remediation |
| **Application Security** | Application.Read.All, Directory.Read.All | Audit overprivileged apps; detect apps with dangerous Graph permissions |
| **Device Compliance** | Device.Read.All, Policy.Read.All | Validate Intune compliance; identify unmanaged devices |
| **Historical Audit** | All permissions | Delta detection (~99% efficiency); 90-day event retention; permanent change history |

---

## 3. Azure Resource Manager (ARM) Permissions

The Function App's managed identity requires **Reader** role at:

| Scope | Why Needed | What For |
|-------|------------|----------|
| **Tenant Root** (optional, or per-subscription) | Read Azure resource hierarchy | Collect management groups, subscriptions, resource groups |
| **Target Subscriptions** (minimum) | Read Azure resources | Collect VMs, Key Vaults, Storage Accounts, Function Apps, Logic Apps, etc. (11 resource types) |

**Alternative:** If tenant-level Reader is too broad, grant Reader on each target subscription individually.

### Resources Collected from Azure

| Resource Type | ARM Provider | Why Collected |
|---------------|--------------|---------------|
| Key Vaults | Microsoft.KeyVault/vaults | Audit access policies, RBAC mode, soft delete |
| Virtual Machines | Microsoft.Compute/virtualMachines | Track managed identities, security posture |
| Storage Accounts | Microsoft.Storage/storageAccounts | Audit public access, TLS version, encryption |
| Function Apps | Microsoft.Web/sites (kind=functionapp) | Track managed identities, HTTPS enforcement |
| Logic Apps | Microsoft.Logic/workflows | Track managed identities |
| Web Apps | Microsoft.Web/sites (kind=app) | Track managed identities, client certs |
| Automation Accounts | Microsoft.Automation/automationAccounts | Track privileged automation |
| AKS Clusters | Microsoft.ContainerService/managedClusters | Audit private cluster mode, local accounts |
| Container Registries | Microsoft.ContainerRegistry/registries | Check admin user status |
| VM Scale Sets | Microsoft.Compute/virtualMachineScaleSets | Track managed identities |
| Data Factories | Microsoft.DataFactory/factories | Audit public network access |

---

## 4. Pre-Deployment Requirements

### 4.1 Software/Tooling

| Tool | Version | Why Needed | Install Command |
|------|---------|------------|-----------------|
| PowerShell | 7.4+ | Run deployment script | [Download](https://aka.ms/powershell) |
| Azure CLI | Latest | Alternative auth method | `winget install Microsoft.AzureCLI` |
| Az PowerShell Modules | Latest | Deploy Bicep templates | `Install-Module Az -Scope CurrentUser` |
| Azure Functions Core Tools | 4.x | Deploy function code | `npm install -g azure-functions-core-tools@4` |

### 4.2 Network Requirements

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| `graph.microsoft.com` | 443 | HTTPS | Microsoft Graph API |
| `management.azure.com` | 443 | HTTPS | Azure Resource Manager |
| `*.blob.core.windows.net` | 443 | HTTPS | Storage Account access |
| `*.documents.azure.com` | 443 | HTTPS | Cosmos DB access |
| `*.azurewebsites.net` | 443 | HTTPS | Function App runtime |
| `*.vault.azure.net` | 443 | HTTPS | Key Vault access |

**No inbound internet access required** - all communication is outbound only.

### 4.3 License Requirements

| License | Why Needed | Impact if Missing |
|---------|------------|-------------------|
| **Entra ID P1** (minimum) | Access Conditional Access policies, sign-in logs | Cannot collect CA policies or sign-in events |
| **Entra ID P2** (recommended) | Access Identity Protection data, risky users | Cannot collect user risk levels (feature degrades gracefully) |
| **Microsoft Intune** (optional) | Collect device compliance and app protection policies | Intune policy collection will fail (other features unaffected) |

---

## 5. Estimated Costs

### Azure Resource Costs (Monthly, Development Environment)

| Resource | SKU | Estimated Cost | Notes |
|----------|-----|----------------|-------|
| Storage Account | Standard LRS | $5-10 | 7-day retention (auto-delete) |
| Cosmos DB | Serverless | $25-50 | Pay per RU consumed; delta detection reduces writes by ~99% |
| Function App | Consumption | $5-15 | Pay per execution; runs every 6 hours |
| Application Insights | Pay-as-you-go | $5-10 | Log retention 30 days |
| Log Analytics | Pay-as-you-go | $5-10 | Workspace for monitoring |
| Key Vault | Standard | $1-2 | Minimal operations |
| **Total** | | **~$50-100/month** | Development environment; production may vary |

**Production Environment:** Costs scale with tenant size and collection frequency. For large tenants (50K+ users), budget $200-500/month.

---

## 6. Deployment Summary

### Deployment Steps

1. **Infrastructure Deployment** (30-45 minutes)
   - Run `deploy.ps1` to create Azure resources (Bicep template)
   - Assign Azure RBAC roles to Function App managed identity (automated)
   - Deploy Function App code (automated via `func azure functionapp publish`)

2. **Entra ID Permissions** (15-30 minutes)
   - Grant 14 Microsoft Graph API permissions to Function App managed identity (automated in deploy.ps1)
   - **Requires Global Administrator or Privileged Role Administrator consent**

3. **Testing** (15 minutes)
   - Trigger initial collection run (manual HTTP trigger or wait for timer)
   - Verify data in Blob Storage and Cosmos DB
   - Check Application Insights for errors

**Total Deployment Time:** 1-2 hours (mostly Azure resource provisioning)

### Post-Deployment Access

| Resource | Access Level | Who Needs Access |
|----------|--------------|------------------|
| Azure Resource Group | Reader | Security analysts, platform owners |
| Cosmos DB | Data Reader | Security analysts (via Azure Portal or Data Explorer) |
| Application Insights | Reader | Security analysts, operations team |
| Storage Account | Storage Blob Data Reader | Security analysts (troubleshooting only) |
| Function App | Reader | Operations team (monitoring only) |

**Recommendation:** Use Entra ID PIM to provide just-in-time access to resources instead of standing assignments.

---

## 7. Security & Compliance

### Data Protection

| Aspect | Implementation |
|--------|----------------|
| **Data Classification** | Identity and security configuration data (no passwords/secrets collected) |
| **Encryption at Rest** | All Azure resources use Microsoft-managed encryption |
| **Encryption in Transit** | TLS 1.2+ enforced on all connections |
| **Data Retention** | Blob: 7-90 days (configurable); Cosmos DB: permanent (audit trail) |
| **Data Residency** | Default region: Sweden Central (configurable at deployment) |
| **Access Control** | Azure RBAC + Entra ID authentication; managed identities only |

### Audit & Compliance

| Capability | How Implemented |
|------------|-----------------|
| **Change Tracking** | All Cosmos DB operations logged to Log Analytics (diagnostic settings) |
| **Tamper Protection** | Custom Cosmos DB role prevents deletion of audit records |
| **Activity Logging** | All Graph API calls logged in Entra ID sign-in logs (service principal activity) |
| **Operational Monitoring** | Application Insights tracks all function executions, errors, dependencies |

### Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| **Over-privileged Access** | Read-only Graph API permissions; custom Cosmos DB role without delete |
| **Credential Exposure** | Managed identities only (no service principal secrets) |
| **Data Exfiltration** | Azure Private Link (optional); network-restricted storage account |
| **Unauthorized Modifications** | Cosmos DB audit container has delete operation blocked at RBAC level |

---

## 8. What Needs Approval

Each item below may need to be routed to different approval authorities depending on your organization's structure.

### A. Azure Subscription Access
**What:** Permission to create resources in Azure subscription
**Specific Request:** Contributor role on resource group `rg-entrarisk-v3-001` (or create RG + 8 resource types listed in Section 1)
**Why:** Deploy monitoring infrastructure (storage, database, compute)
**Cost Impact:** ~$50-100/month (dev), ~$200-500/month (prod)

### B. Azure Reader Access
**What:** Read access to existing Azure resources across subscriptions
**Specific Request:** Reader role on target subscription(s) or Tenant Root
**Why:** Collect Azure resource inventory (VMs, Key Vaults, Function Apps, etc. - 11 resource types)
**Risk:** Read-only, no modifications possible

### C. Microsoft Graph API Permissions
**What:** Application permissions for Entra ID data access
**Specific Request:** 14 read-only permissions (see Section 2 for full list)
**Approval Mechanism:** Requires admin consent in Entra ID portal or via PowerShell
**Who Can Grant:** Global Administrator or Privileged Role Administrator
**Risk:** Read-only, no write/modify/delete capabilities

### D. Network Egress
**What:** Outbound HTTPS access from Function App
**Destinations:** `graph.microsoft.com`, `management.azure.com`, `*.documents.azure.com`, `*.blob.core.windows.net`
**Why:** Function App needs to call Microsoft APIs and access Azure resources
**Inbound:** None required

### E. License Requirements
**What:** Entra ID licensing validation
**Required:** Entra ID P1 (minimum) for Conditional Access data
**Optional:** Entra ID P2 for Identity Protection data; Microsoft Intune for device policies
**Impact if Missing:** Some features unavailable (solution degrades gracefully)

### F. Data Governance
**What:** Approval for data collection and retention
**Data Types:** User accounts, group memberships, role assignments, Azure resource configs (no passwords/secrets)
**Retention:** Blob storage 7-90 days; Cosmos DB permanent audit trail
**Classification:** Internal - Security Configuration Data
**Compliance:** GDPR/privacy considerations for identity data

---

## 9. Support & Documentation

- **Full Documentation:** `/docs/README-v3.5.md` (architecture, data flow, queries)
- **Deployment Script:** `/Infrastructure/deploy.ps1`
- **Bicep Template:** `/Infrastructure/main.bicep`
- **GitHub Repository:** [Link to repo if available]

For questions or clarifications, contact: [Your contact info]

---

**End of Request Document**
