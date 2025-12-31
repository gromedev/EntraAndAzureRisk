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


**PART 1: Cosmos DB Output Bindings Refactor**

---

**File 1: FunctionApp/IndexInCosmosDB/function.json**

```json
{
  "bindings": [
    {
      "name": "ActivityInput",
      "type": "activityTrigger",
      "direction": "in"
    },
    {
      "name": "usersRawOut",
      "type": "cosmosDB",
      "direction": "out",
      "databaseName": "EntraData",
      "containerName": "users_raw",
      "connection": "CosmosDbConnectionString",
      "createIfNotExists": false,
      "partitionKey": "/objectId"
    },
    {
      "name": "userChangesOut",
      "type": "cosmosDB",
      "direction": "out",
      "databaseName": "EntraData",
      "containerName": "user_changes",
      "connection": "CosmosDbConnectionString",
      "createIfNotExists": false,
      "partitionKey": "/snapshotId"
    },
    {
      "name": "snapshotsOut",
      "type": "cosmosDB",
      "direction": "out",
      "databaseName": "EntraData",
      "containerName": "snapshots",
      "connection": "CosmosDbConnectionString",
      "createIfNotExists": false,
      "partitionKey": "/id"
    },
    {
      "name": "usersRawIn",
      "type": "cosmosDB",
      "direction": "in",
      "databaseName": "EntraData",
      "containerName": "users_raw",
      "connection": "CosmosDbConnectionString",
      "sqlQuery": "SELECT c.objectId, c.userPrincipalName, c.accountEnabled, c.userType, c.lastSignInDateTime, c.lastModified FROM c"
    }
  ]
}
```

---

**File 2: FunctionApp/IndexInCosmosDB/run.ps1**

Replace entire file with:

```powershell
#region Index in Cosmos DB Activity - DELTA CHANGE DETECTION with Output Bindings
<#
.SYNOPSIS
    Indexes users in Cosmos DB with delta change detection using native bindings
.DESCRIPTION
    - Reads users from Blob Storage (JSONL format)
    - Uses Cosmos DB input binding to read existing users
    - Compares and identifies changes
    - Uses output bindings to write changes (no REST API auth needed)
    - Logs all changes to user_changes container
    - Writes summary to snapshots container
#>
#endregion

param($ActivityInput, $usersRawIn)

Import-Module EntraDataCollection

try {
    Write-Verbose "Starting Cosmos DB indexing with delta detection (output bindings)"
    
    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $enableDelta = $env:ENABLE_DELTA_DETECTION -eq 'true'
    
    $timestamp = $ActivityInput.Timestamp
    $userCount = $ActivityInput.UserCount
    $blobName = $ActivityInput.BlobName
    
    Write-Verbose "Configuration:"
    Write-Verbose "  Blob: $blobName"
    Write-Verbose "  Users: $userCount"
    Write-Verbose "  Delta detection: $enableDelta"
    
    # Get storage token (cached)
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    
    #region Step 1: Read users from Blob
    Write-Verbose "Reading users from Blob Storage..."
    
    $blobUri = "https://$storageAccountName.blob.core.windows.net/raw-data/$blobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'AppendBlob'
    }
    
    $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $headers
    
    # Parse JSONL into HashMap
    $currentUsers = @{}
    $lineNumber = 0
    
    foreach ($line in ($blobContent -split "`n")) {
        $lineNumber++
        if ($line.Trim()) {
            try {
                $user = $line | ConvertFrom-Json
                $currentUsers[$user.objectId] = $user
            }
            catch {
                Write-Warning "Failed to parse line $lineNumber`: $_"
            }
        }
    }
    
    Write-Verbose "Parsed $($currentUsers.Count) users from Blob"
    #endregion
    
    #region Step 2: Read existing users from Cosmos (via input binding)
    $existingUsers = @{}
    
    if ($enableDelta -and $usersRawIn) {
        Write-Verbose "Reading existing users from Cosmos DB (input binding)..."
        
        foreach ($doc in $usersRawIn) {
            $existingUsers[$doc.objectId] = $doc
        }
        
        Write-Verbose "Found $($existingUsers.Count) existing users in Cosmos"
    }
    #endregion
    
    #region Step 3: Delta detection
    $newUsers = @()
    $modifiedUsers = @()
    $unchangedUsers = @()
    $deletedUsers = @()
    $changeLog = @()
    
    # Check current users
    foreach ($objectId in $currentUsers.Keys) {
        $currentUser = $currentUsers[$objectId]
        
        if (-not $existingUsers.ContainsKey($objectId)) {
            # NEW user
            $newUsers += $currentUser
            
            $changeLog += @{
                id = [Guid]::NewGuid().ToString()
                objectId = $objectId
                changeType = 'new'
                changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
                newValue = $currentUser
            }
        }
        else {
            # Check if modified
            $existingUser = $existingUsers[$objectId]
            
            $changed = $false
            $delta = @{}
            
            $fieldsToCompare = @('accountEnabled', 'userType', 'lastSignInDateTime', 'userPrincipalName')
            
            foreach ($field in $fieldsToCompare) {
                $currentValue = $currentUser.$field
                $existingValue = $existingUser.$field
                
                if ($currentValue -ne $existingValue) {
                    $changed = $true
                    $delta[$field] = @{
                        old = $existingValue
                        new = $currentValue
                    }
                }
            }
            
            if ($changed) {
                # MODIFIED user
                $modifiedUsers += $currentUser
                
                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'modified'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingUser
                    newValue = $currentUser
                    delta = $delta
                }
            }
            else {
                # UNCHANGED
                $unchangedUsers += $objectId
            }
        }
    }
    
    # Check for deleted users
    if ($enableDelta) {
        foreach ($objectId in $existingUsers.Keys) {
            if (-not $currentUsers.ContainsKey($objectId)) {
                # DELETED user
                $deletedUsers += $existingUsers[$objectId]
                
                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'deleted'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingUsers[$objectId]
                }
            }
        }
    }
    
    Write-Verbose "Delta summary:"
    Write-Verbose "  New: $($newUsers.Count)"
    Write-Verbose "  Modified: $($modifiedUsers.Count)"
    Write-Verbose "  Deleted: $($deletedUsers.Count)"
    Write-Verbose "  Unchanged: $($unchangedUsers.Count)"
    #endregion
    
    #region Step 4: Write changes to Cosmos using output bindings
    $usersToWrite = @()
    $usersToWrite += $newUsers
    $usersToWrite += $modifiedUsers
    
    if ($usersToWrite.Count -gt 0 -or (-not $enableDelta)) {
        Write-Verbose "Preparing $($usersToWrite.Count) changed users for Cosmos..."
        
        # If delta disabled, write all users
        if (-not $enableDelta) {
            $usersToWrite = $currentUsers.Values
            Write-Verbose "Delta detection disabled - writing all $($usersToWrite.Count) users"
        }
        
        # Prepare documents
        $docsToWrite = @()
        foreach ($user in $usersToWrite) {
            $docsToWrite += @{
                id = $user.objectId
                objectId = $user.objectId
                userPrincipalName = $user.userPrincipalName
                accountEnabled = $user.accountEnabled
                userType = $user.userType
                createdDateTime = $user.createdDateTime
                lastSignInDateTime = $user.lastSignInDateTime
                collectionTimestamp = $user.collectionTimestamp
                lastModified = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
            }
        }
        
        # Write using output binding
        Push-OutputBinding -Name usersRawOut -Value $docsToWrite
        Write-Verbose "Queued $($docsToWrite.Count) users to users_raw container"
    }
    else {
        Write-Verbose "No changes detected - skipping user writes"
    }
    #endregion
    
    #region Step 5: Write change log using output binding
    if ($changeLog.Count -gt 0) {
        Write-Verbose "Queuing $($changeLog.Count) change events..."
        Push-OutputBinding -Name userChangesOut -Value $changeLog
        Write-Verbose "Queued $($changeLog.Count) change events to user_changes container"
    }
    #endregion
    
    #region Step 6: Write snapshot summary using output binding
    $snapshotDoc = @{
        id = $timestamp
        snapshotId = $timestamp
        collectionTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'users'
        totalUsers = $currentUsers.Count
        newUsers = $newUsers.Count
        modifiedUsers = $modifiedUsers.Count
        deletedUsers = $deletedUsers.Count
        unchangedUsers = $unchangedUsers.Count
        cosmosWriteCount = $usersToWrite.Count
        blobPath = $blobName
        deltaDetectionEnabled = $enableDelta
    }
    
    Push-OutputBinding -Name snapshotsOut -Value $snapshotDoc
    Write-Verbose "Queued snapshot summary to snapshots container"
    #endregion
    
    Write-Verbose "Cosmos DB indexing complete!"
    
    return @{
        Success = $true
        TotalUsers = $currentUsers.Count
        NewUsers = $newUsers.Count
        ModifiedUsers = $modifiedUsers.Count
        DeletedUsers = $deletedUsers.Count
        UnchangedUsers = $unchangedUsers.Count
        CosmosWriteCount = $usersToWrite.Count
        SnapshotId = $timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalUsers = 0
        NewUsers = 0
        ModifiedUsers = 0
        DeletedUsers = 0
        UnchangedUsers = 0
        CosmosWriteCount = 0
        SnapshotId = $timestamp
    }
}
```

---

**File 3: FunctionApp/Orchestrator/run.ps1**

Find line ~173 and replace the write efficiency calculation:

```powershell
# OLD (causes divide by zero):
CosmosWriteReduction = if ($indexResult.TotalUsers -gt 0) {
    [math]::Round((1 - ($indexResult.CosmosWriteCount / $indexResult.TotalUsers)) * 100, 2)
} else { 0 }

# NEW (safe):
CosmosWriteReduction = if ($indexResult.TotalUsers -gt 0 -and $indexResult.Success) {
    [math]::Round((1 - ($indexResult.CosmosWriteCount / $indexResult.TotalUsers)) * 100, 2)
} else { 
    0 
}
```

And around line 173 in the Summary section:

```powershell
# OLD:
WriteEfficiency = "$($indexResult.CosmosWriteCount) writes instead of $($indexResult.TotalUsers) ($(100 - [math]::Round(($indexResult.CosmosWriteCount / $indexResult.TotalUsers) * 100, 2))% reduction)"

# NEW:
WriteEfficiency = if ($indexResult.TotalUsers -gt 0 -and $indexResult.Success) {
    "$($indexResult.CosmosWriteCount) writes instead of $($indexResult.TotalUsers) ($(100 - [math]::Round(($indexResult.CosmosWriteCount / $indexResult.TotalUsers) * 100, 2))% reduction)"
} else {
    "No writes completed"
}
```

---

**File 4: Add Cosmos DB Connection String to Function App**

Run this command:

```powershell
# Get Cosmos DB account key
$cosmosKeys = az cosmosdb keys list --name cosno-entrarisk-dev-36jut3xd6y2so --resource-group rg-entrarisk-pilot-001 --type connection-strings --query "connectionStrings[0].connectionString" -o tsv

# Add to Function App settings
az functionapp config appsettings set --name func-entrarisk-data-dev-36jut3xd6y2so --resource-group rg-entrarisk-pilot-001 --settings "CosmosDbConnectionString=$cosmosKeys"
```

---

**Redeploy:**

```powershell
cd FunctionApp
func azure functionapp publish func-entrarisk-data-dev-36jut3xd6y2so --powershell
```

---

**PART 2: Option 3 - Az.CosmosDB Module Approach**

If output bindings don't work, use the Az.CosmosDB PowerShell module:

**Step 1: Add to requirements.psd1**

```powershell
@{
    'Az.Accounts' = '2.*'
    'Az.Storage' = '6.*'
    'Az.KeyVault' = '5.*'
    'Az.CosmosDB' = '1.*'  # Add this
}
```

**Step 2: In IndexInCosmosDB/run.ps1, replace Cosmos operations:**

```powershell
# Read existing users
$existingDocs = Invoke-AzCosmosDBSqlQuery `
    -ResourceGroupName "rg-entrarisk-pilot-001" `
    -AccountName "cosno-entrarisk-dev-36jut3xd6y2so" `
    -DatabaseName "EntraData" `
    -ContainerName "users_raw" `
    -Query "SELECT * FROM c"

# Write document
New-AzCosmosDBSqlDocument `
    -ResourceGroupName "rg-entrarisk-pilot-001" `
    -AccountName "cosno-entrarisk-dev-36jut3xd6y2so" `
    -DatabaseName "EntraData" `
    -ContainerName "users_raw" `
    -Id $doc.id `
    -PartitionKeyValue $doc.objectId `
    -Document $doc
```

**Pros:** Uses official Azure module, fully supported  
**Cons:** Slower (REST API calls), requires managed identity RBAC, larger module dependency


**The CLI command structure is wrong. Use the Azure Portal instead:**

**Option 1: Azure Portal (Easiest)**

1. Go to: https://portal.azure.com
2. Navigate to: `cosno-entrarisk-dev-36jut3xd6y2so` (Cosmos DB account)
3. Click "Data Explorer" in left menu
4. Expand: `EntraData` → `snapshots`
5. Click "Items"
6. You should see 1 document with your timestamp

---

**Option 2: Check blob storage (also confirms data collected):**

```bash
az storage blob list --account-name stentrariskdev36jut3xd6y2so --container-name raw-data --auth-mode login --output table
```

This will show the blob file created: `2025-12-31T08-43-58Z/2025-12-31T08-43-58Z-users.jsonl`

---

**Option 3: Trigger another run to test delta detection:**

```powershell
$f="VATqkmerGDlLnJcKAlGs8-lIBwiv50c3dDcJBzjcMe-rAzFuiw7Guw=="
$r = Invoke-RestMethod -Uri "https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/httptrigger?code=$f" -Method Post
Start-Sleep -Seconds 10
Invoke-RestMethod -Uri $r.statusQueryGetUri
```

**The second run should show:**
- Total users: 52
- New users: 0
- Modified users: 0-5 (depending on changes)
- **Cosmos writes: 0-5 (instead of 52)** ← This proves delta detection works

Try Option 2 (blob storage) - that's the easiest to verify.