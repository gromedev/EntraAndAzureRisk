# V3.5 Deployment Guide

> **Purpose:** Step-by-step deployment guide with all required permissions and troubleshooting notes.
> **Last Updated:** 2026-01-08

---

## Prerequisites

1. Azure CLI installed and logged in
2. Azure Functions Core Tools installed
3. Subscription Owner or Contributor + User Access Administrator
4. Global Administrator or Privileged Role Administrator in Entra ID

---

## Step 1: Create Resource Group

```bash
az group create --name "rg-entrarisk-v35-001" --location "swedencentral"
```

---

## Step 2: Deploy Infrastructure (Bicep)

```bash
cd /Users/thomas/git/GitHub/EntraAndAzureRisk/Infrastructure

az deployment group create \
  --resource-group "rg-entrarisk-v35-001" \
  --template-file main.bicep \
  --parameters workloadName="entrariskv35" \
               environment="dev" \
               tenantId="<YOUR_TENANT_ID>" \
               deployGremlin=false
```

**Note:** `deployGremlin=false` skips Gremlin database (deferred to V3.6).

Save the outputs - you'll need:
- `functionAppName`
- `storageAccountName`
- `cosmosDbAccountName`
- `functionAppIdentityPrincipalId`

---

## Step 3: Deploy Function Code

```bash
cd /Users/thomas/git/GitHub/EntraAndAzureRisk/FunctionApp

func azure functionapp publish <FUNCTION_APP_NAME> --powershell
```

---

## Step 4: Grant Microsoft Graph Permissions

**CRITICAL:** The Function App managed identity needs these Graph API permissions.

### Required Permissions

| Permission | App Role ID | Purpose |
|------------|-------------|---------|
| User.Read.All | `df021288-bdef-4463-88db-98f22de89214` | Read all users |
| Group.Read.All | `5b567255-7703-4780-807c-7be8301ae99b` | Read all groups |
| Application.Read.All | `9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30` | Read app registrations |
| Directory.Read.All | `7ab1d382-f21e-4acd-a863-ba3e13f7da61` | Read directory objects |
| DeviceManagementConfiguration.Read.All | `dc377aa6-52d8-4e23-b271-2a7ae04cedf3` | Read Intune policies |
| IdentityRiskyUser.Read.All | `dc5007c0-2d7d-4c42-879c-2dab87571379` | Read risky users (P2) |
| AuditLog.Read.All | `b0afded3-3588-46d8-8b3d-9842eff778da` | Read audit logs |
| Policy.Read.All | `246dd0d5-5bd0-4def-940b-0421030a5b68` | Read CA policies |
| RoleManagement.Read.All | `c7fbd983-d9aa-4fa7-84b8-17382c103bc4` | Read directory roles |
| PrivilegedAccess.Read.AzureADGroup | `01e37dc9-c035-40bd-b438-b2879c4870a6` | Read PIM group assignments |
| UserAuthenticationMethod.Read.All | `38d9df27-64da-44fd-b7c5-a6fbac20248f` | Read auth methods |

### Grant Permissions Script

```bash
# Get Microsoft Graph service principal ID
GRAPH_SP_ID=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query "[0].id" -o tsv)

# Get Function App managed identity principal ID (from deployment output)
MANAGED_IDENTITY_ID="<FUNCTION_APP_IDENTITY_PRINCIPAL_ID>"

# Grant each permission
PERMISSIONS=(
    "df021288-bdef-4463-88db-98f22de89214"  # User.Read.All
    "5b567255-7703-4780-807c-7be8301ae99b"  # Group.Read.All
    "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"  # Application.Read.All
    "7ab1d382-f21e-4acd-a863-ba3e13f7da61"  # Directory.Read.All
    "dc377aa6-52d8-4e23-b271-2a7ae04cedf3"  # DeviceManagementConfiguration.Read.All
    "dc5007c0-2d7d-4c42-879c-2dab87571379"  # IdentityRiskyUser.Read.All
    "b0afded3-3588-46d8-8b3d-9842eff778da"  # AuditLog.Read.All
    "246dd0d5-5bd0-4def-940b-0421030a5b68"  # Policy.Read.All
    "c7fbd983-d9aa-4fa7-84b8-17382c103bc4"  # RoleManagement.Read.All
    "01e37dc9-c035-40bd-b438-b2879c4870a6"  # PrivilegedAccess.Read.AzureADGroup
    "38d9df27-64da-44fd-b7c5-a6fbac20248f"  # UserAuthenticationMethod.Read.All
)

for PERM in "${PERMISSIONS[@]}"; do
    echo "Granting permission $PERM..."
    az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MANAGED_IDENTITY_ID/appRoleAssignments" \
        --headers "Content-Type=application/json" \
        --body "{\"principalId\":\"$MANAGED_IDENTITY_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$PERM\"}" 2>&1 || true
done
```

### Verify Permissions

```bash
az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MANAGED_IDENTITY_ID/appRoleAssignments" \
    --query "value[].{permission:appRoleId, resource:resourceDisplayName}" -o table
```

---

## Step 5: Get Function Keys

```bash
# Dashboard key
az functionapp function keys list \
  --resource-group "rg-entrarisk-v35-001" \
  --name "<FUNCTION_APP_NAME>" \
  --function-name "Dashboard" \
  --query "default" -o tsv

# HTTP Trigger key
az functionapp function keys list \
  --resource-group "rg-entrarisk-v35-001" \
  --name "<FUNCTION_APP_NAME>" \
  --function-name "HttpTrigger" \
  --query "default" -o tsv
```

---

## Step 6: Trigger Data Collection

**IMPORTANT:** The HttpTrigger only accepts POST requests (not GET).

```bash
curl -X POST "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/httptrigger?code=<HTTP_TRIGGER_KEY>"
```

This returns a status URL to monitor the orchestration:

```bash
# Check orchestration status
curl "<STATUS_QUERY_GET_URI_FROM_RESPONSE>"
```

---

## Step 7: Verify Deployment

### Check Dashboard

```bash
curl "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/dashboard?code=<DASHBOARD_KEY>"
```

### Verify Counts Match Tenant

```bash
# Users
az rest --method GET --uri "https://graph.microsoft.com/v1.0/users/\$count" --headers "ConsistencyLevel=eventual"

# Groups
az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/\$count" --headers "ConsistencyLevel=eventual"

# Service Principals
az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/\$count" --headers "ConsistencyLevel=eventual"
```

---

## Troubleshooting

### 403 Errors on Graph API

**Symptom:** Functions fail with "Request Authorization failed"

**Cause:** Missing Graph API permissions on managed identity

**Fix:** Grant the required permissions (see Step 4)

### 404 on HttpTrigger

**Symptom:** `curl` to HttpTrigger returns 404

**Cause:** HttpTrigger only accepts POST requests

**Fix:** Use `curl -X POST` instead of GET

### Auth Methods 403

**Symptom:** "Failed to get auth methods" warnings in logs

**Cause:** Missing `UserAuthenticationMethod.Read.All` permission

**Fix:** Grant permission with app role ID `38d9df27-64da-44fd-b7c5-a6fbac20248f`

### Storage Access Denied

**Symptom:** Cannot list blobs with `--auth-mode login`

**Cause:** User lacks Storage Blob Data Contributor role

**Fix:**
```bash
USER_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "$USER_ID" \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/<STORAGE>"
```

### Risky Users API Fails

**Symptom:** Risk data not populated in users

**Cause:** Tenant doesn't have Entra ID P2 license

**Impact:** Non-blocking - users collected without risk data

### Device.Read.All Permission Error

**Symptom:** "Permission being assigned was not found on application"

**Cause:** Known issue with some legacy app role IDs

**Impact:** Non-blocking - devices may be collected via Directory.Read.All

---

## License Requirements

| Feature | License Required |
|---------|------------------|
| Basic collection | Entra ID Free |
| Risky users | Entra ID P2 |
| PIM data | Entra ID P2 |
| Auth methods | Entra ID P1+ |

---

## Quick Reference URLs

```
Dashboard:    https://<FUNCTION_APP>.azurewebsites.net/api/dashboard?code=<KEY>
HTTP Trigger: https://<FUNCTION_APP>.azurewebsites.net/api/httptrigger?code=<KEY> (POST only)
```

---

## Resource Naming Convention

| Resource | Pattern | Example |
|----------|---------|---------|
| Resource Group | `rg-entrarisk-v{version}-001` | `rg-entrarisk-v35-001` |
| Function App | `func-{workload}-data-{env}-{unique}` | `func-entrariskv35-data-dev-enkqnnv64liny` |
| Storage Account | `st{workload}{env}{unique}` (max 24 chars) | `stentrariskv35devenkqnnv` |
| Cosmos DB | `cosno-{workload}-{env}-{unique}` | `cosno-entrariskv35-dev-enkqnnv64liny` |
| App Insights | `appi-{workload}-{env}-001` | `appi-entrariskv35-dev-001` |

---

**End of Deployment Guide**
