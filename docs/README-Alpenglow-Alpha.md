# Alpenglow Alpha

> **Version:** 1.0-alpha
> **Last Updated:** 2026-01-15
> **Branch:** alpenglow-alpha
> **Purpose:** Security-isolated Entra ID and Azure risk analysis platform

---

## Overview

Alpenglow is a data collection and analysis platform for Microsoft Entra ID and Azure security data. It features a **security-isolated architecture** with separate Function Apps for data collection and dashboard presentation.

### Key Features
- Collects Entra ID and Azure security data via Microsoft Graph API and Azure Resource Manager API
- **Serverless Cosmos DB** (~$8/month vs ~$120/month provisioned)
- **Security isolation** - Dashboard has NO access to Graph API
- Delta detection with ~99% write reduction
- Historical trend analysis and audit correlation

---

## Security Architecture

```
+------------------------------------------------------------------+
|                    Azure Resource Group                           |
|                    rg-alpenglow-dev-001                           |
+------------------------------------------------------------------+
|                                                                   |
|  +-------------------------+     +-------------------------+      |
|  | func-alpenglow-data     |     | func-alpenglow-www      |      |
|  | (Data Collection)       |     | (Dashboard only)        |      |
|  +-------------------------+     +-------------------------+      |
|  | Managed Identity A      |     | Managed Identity B      |      |
|  |                         |     |                         |      |
|  | Permissions:            |     | Permissions:            |      |
|  | - 15 Graph API perms    |     | - Cosmos DB (conn str)  |      |
|  | - Cosmos DB RBAC        |     | - NO Graph API          |      |
|  | - Storage Blob          |     | - NO Storage            |      |
|  +-------------------------+     +-------------------------+      |
|            |                           |                          |
|            v                           v                          |
|  +---------------------------------------------------+           |
|  |              Cosmos DB (Serverless)                |           |
|  |              cosno-alpenglow-dev-*                 |           |
|  +---------------------------------------------------+           |
|                                                                   |
+------------------------------------------------------------------+
```

### Security Benefits

If the Dashboard (www) function app is compromised:
- Attacker can only READ Cosmos data (via connection string)
- **Cannot access Graph API** (no permissions assigned)
- **Cannot modify blobs** (no storage permissions)
- **Cannot affect data collection** (separate identity)

---

## Project Structure

```
/FunctionApp-Data/           # Data collection (Graph API permissions)
├── host.json               # DurableTask hub: AlpenglowHub
├── profile.ps1             # Loads EntraDataCollection module
├── requirements.psd1       # Az modules
├── Modules/
│   └── EntraDataCollection/
├── Orchestrator/
├── HttpTrigger/
├── TimerTrigger/
├── Collect*/               # 12 collectors
├── DeriveEdges/
├── DeriveVirtualEdges/
├── Index*/                 # 5 indexers
├── ProjectGraphToGremlin/
└── GenerateGraphSnapshots/

/FunctionApp-www/           # Dashboard only (minimal permissions)
├── host.json               # No DurableTask
├── profile.ps1             # Simplified - no modules
├── requirements.psd1       # Minimal
└── Dashboard/
    ├── function.json
    └── run.ps1
```

---

## Deployment

### Prerequisites
- Azure CLI (`az`)
- Azure Functions Core Tools (`func`)
- PowerShell 7+

### Quick Deploy
```powershell
cd Scripts
.\deploy.ps1 -SubscriptionId "your-sub-id" -TenantId "your-tenant-id"
```

The script will:
1. Create resource group `rg-alpenglow-dev-001`
2. Deploy infrastructure via Bicep (both function apps, Cosmos DB, Storage, etc.)
3. Assign Graph API permissions to the Data function app only
4. Deploy code to both function apps

### Manual Deployment
```powershell
# Deploy Data Function App
cd FunctionApp-Data
func azure functionapp publish func-alpenglow-data-dev-<suffix> --powershell

# Deploy www Function App (Dashboard)
cd FunctionApp-www
func azure functionapp publish func-alpenglow-www-dev-<suffix> --powershell
```

---

## Cosmos DB Containers

| Container | Partition Key | TTL | Purpose |
|-----------|---------------|-----|---------|
| principals | /objectId | -1 | Users, groups, SPs, devices |
| resources | /resourceType | -1 | Applications, Azure resources |
| edges | /edgeType | -1 | All relationships |
| policies | /policyType | -1 | CA, Intune, security policies |
| events | /eventDate | 90d | Sign-ins, audits |
| audit | /auditDate | -1 | Change tracking (permanent) |

---

## URLs

After deployment:
- **Data App:** `https://func-alpenglow-data-dev-<suffix>.azurewebsites.net`
- **Dashboard:** `https://func-alpenglow-www-dev-<suffix>.azurewebsites.net/api/dashboard`

---

## Naming Convention

| Resource Type | Pattern | Example |
|---------------|---------|---------|
| Data Function App | `func-alpenglow-data-{env}-{suffix}` | `func-alpenglow-data-dev-xyz123` |
| www Function App | `func-alpenglow-www-{env}-{suffix}` | `func-alpenglow-www-dev-xyz123` |
| Resource Group | `rg-alpenglow-{env}-001` | `rg-alpenglow-dev-001` |
| Cosmos DB | `cosno-alpenglow-{env}-{suffix}` | `cosno-alpenglow-dev-xyz123` |
| Storage | `stalpenglow{env}{suffix}` | `stalpenglowdevxyz123` |

---

## Migrating from EntraRisk v3.5

This is a **fresh deployment** - not an upgrade. Key differences:
- Separate function apps (security isolation)
- Serverless Cosmos DB (cost reduction)
- New naming convention (alpenglow instead of entrarisk)
- Same data model and collectors

---

## License

Private - Not for distribution.
