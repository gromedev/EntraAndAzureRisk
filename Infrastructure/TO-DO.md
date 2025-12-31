**THREE CRITICAL ISSUES FOUND:**

**Issue 1: Missing Graph Permission (BLOCKING)**

```
"The principal does not have required Microsoft Graph permission(s): AuditLog.Read.All"
```

Your code requests `signInActivity` which requires `AuditLog.Read.All`, but you only granted `User.Read.All`.

**Issue 2: Az Modules Not Loading (profile.ps1)**

```
The term 'Connect-AzAccount' is not recognized
The term 'Set-AzContext' is not recognized
```

The Az.Accounts module isn't loading. But this is non-critical since managed identity tokens work via IMDS.

**Issue 3: Function Timeout**

10-minute timeout hit because Graph API kept failing due to missing permission.

---

**FIX - Two Options:**

**Option A: Grant Additional Permission (Recommended)**

```powershell
# Get the managed identity
$managedIdentity = Get-AzADServicePrincipal -DisplayName "func-entrarisk-data-dev-36jut3xd6y2so"

# Get Graph service principal
$graphSP = Get-AzADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Find AuditLog.Read.All permission
$auditLogPermission = $graphSP.AppRole | Where-Object { 
    $_.Value -eq "AuditLog.Read.All" -and $_.AllowedMemberType -contains "Application" 
}

# Grant permission
New-AzADServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentity.Id `
    -ResourceId $graphSP.Id `
    -AppRoleId $auditLogPermission.Id
```

**Option B: Remove signInActivity from Code (Quick Fix)**

Edit `FunctionApp/CollectEntraUsers/run.ps1` line ~119:

Change:
```powershell
$selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity"
```

To:
```powershell
$selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime"
```

Then redeploy:
```bash
cd FunctionApp
func azure functionapp publish func-entrarisk-data-dev-36jut3xd6y2so --powershell
```

**I recommend Option A** - grant the permission so you get sign-in data.


**ROOT CAUSE IDENTIFIED:**

**Issue 1: Cosmos DB Authentication Failed (401 Unauthorized)**

```
"Authorization header doesn't confirm to the required format"
```

The managed identity token for Cosmos DB is malformed. The module uses bearer token auth, but Cosmos DB REST API needs a specific token format.

**Issue 2: Divide by Zero Error**

```
"Attempted to divide by zero" at line 173
```

Because IndexInCosmosDB failed, it returned `TotalUsers = 0`, then the orchestrator tried to calculate write efficiency percentage by dividing by zero.

---

**THE FIX:**

The Cosmos DB authentication in the module is using **bearer tokens** (like Graph API), but Cosmos DB REST API requires **resource tokens or master key auth**.

**You need to use Cosmos DB SDK, not REST API with bearer tokens.**

**Quick Fix - Use Az.CosmosDB Module:**

Replace the Cosmos functions in `EntraDataCollection.psm1`. But this requires major refactoring.

**BETTER OPTION - Use Cosmos DB Output Binding:**

Azure Functions has built-in Cosmos DB bindings that handle auth automatically via managed identity.

**Do you want me to:**
1. Refactor to use Cosmos DB output bindings (recommended, simpler)
2. Fix the REST API authentication (complex, requires master key or resource tokens)
3. Switch to Az.CosmosDB PowerShell module (adds dependency)

Which approach do you prefer?