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

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

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