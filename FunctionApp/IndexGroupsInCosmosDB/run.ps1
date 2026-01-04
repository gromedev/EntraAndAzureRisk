#region Index in Cosmos DB Activity - DELTA CHANGE DETECTION with Output Bindings
<#
.SYNOPSIS
    Indexes groups in Cosmos DB with delta change detection using native bindings
.DESCRIPTION
    - Reads groups from Blob Storage (JSONL format)
    - Uses Cosmos DB input binding to read existing groups
    - Compares and identifies changes
    - Uses output bindings to write changes (no REST API auth needed)
    - Logs all changes to group_changes container
    - Writes summary to snapshots container
#>
#endregion

param($ActivityInput, $groupsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    Write-Verbose "Starting Cosmos DB indexing with delta detection (output bindings)"

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $enableDelta = $env:ENABLE_DELTA_DETECTION -eq 'true'

    $timestamp = $ActivityInput.Timestamp
    $groupCount = $ActivityInput.GroupCount
    $blobName = $ActivityInput.BlobName

    Write-Verbose "Configuration:"
    Write-Verbose "  Blob: $blobName"
    Write-Verbose "  Groups: $groupCount"
    Write-Verbose "  Delta detection: $enableDelta"

    # Get storage token (cached)
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    #region Step 1: Read groups from Blob
    Write-Verbose "Reading groups from Blob Storage..."

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'AppendBlob'
    }

    $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $headers

    # Parse JSONL into HashMap
    $currentGroups = @{}
    $lineNumber = 0

    foreach ($line in ($blobContent -split "`n")) {
        $lineNumber++
        if ($line.Trim()) {
            try {
                $group = $line | ConvertFrom-Json
                $currentGroups[$group.objectId] = $group
            }
            catch {
                Write-Warning "Failed to parse line $lineNumber`: $_"
            }
        }
    }

    Write-Verbose "Parsed $($currentGroups.Count) groups from Blob"
    #endregion

    #region Step 2: Read existing groups from Cosmos (via input binding)
    $existingGroups = @{}

    if ($enableDelta -and $groupsRawIn) {
        Write-Verbose "Reading existing groups from Cosmos DB (input binding)..."

        foreach ($doc in $groupsRawIn) {
            $existingGroups[$doc.objectId] = $doc
        }

        Write-Verbose "Found $($existingGroups.Count) existing groups in Cosmos"
    }
    #endregion

    #region Step 3: Delta detection
    $newGroups = @()
    $modifiedGroups = @()
    $unchangedGroups = @()
    $deletedGroups = @()
    $changeLog = @()

    # Check current groups
    foreach ($objectId in $currentGroups.Keys) {
        $currentGroup = $currentGroups[$objectId]

        if (-not $existingGroups.ContainsKey($objectId)) {
            # NEW group
            $newGroups += $currentGroup

            $changeLog += @{
                id = [Guid]::NewGuid().ToString()
                objectId = $objectId
                changeType = 'new'
                changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
                newValue = $currentGroup
            }
        }
        else {
            # Check if modified
            $existingGroup = $existingGroups[$objectId]

            $changed = $false
            $delta = @{}

            $fieldsToCompare = @(
                'displayName',
                'classification',
                'description',
                'groupTypes',
                'mailEnabled',
                'membershipRule',
                'securityEnabled',
                'isAssignableToRole',
                'visibility',
                'onPremisesSyncEnabled',
                'mail'
            )

            foreach ($field in $fieldsToCompare) {
                if ($field -eq 'groupTypes') {
                    # Special handling for array comparison
                    $currentArray = $currentGroup.$field | Sort-Object
                    $existingArray = $existingGroup.$field | Sort-Object

                    $currentJson = $currentArray | ConvertTo-Json -Compress
                    $existingJson = $existingArray | ConvertTo-Json -Compress

                    if ($currentJson -ne $existingJson) {
                        $changed = $true
                        $delta[$field] = @{
                            old = $existingArray
                            new = $currentArray
                        }
                    }
                }
                else {
                    # Standard comparison
                    $currentValue = $currentGroup.$field
                    $existingValue = $existingGroup.$field

                    if ($currentValue -ne $existingValue) {
                        $changed = $true
                        $delta[$field] = @{
                            old = $existingValue
                            new = $currentValue
                        }
                    }
                }
            }

            if ($changed) {
                # MODIFIED group
                $modifiedGroups += $currentGroup

                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'modified'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingGroup
                    newValue = $currentGroup
                    delta = $delta
                }
            }
            else {
                # UNCHANGED
                $unchangedGroups += $objectId
            }
        }
    }

    # Check for deleted groups
    if ($enableDelta) {
        foreach ($objectId in $existingGroups.Keys) {
            if (-not $currentGroups.ContainsKey($objectId)) {
                # DELETED group
                $deletedGroups += $existingGroups[$objectId]

                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'deleted'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingGroups[$objectId]
                }
            }
        }
    }

    Write-Verbose "Delta summary:"
    Write-Verbose "  New: $($newGroups.Count)"
    Write-Verbose "  Modified: $($modifiedGroups.Count)"
    Write-Verbose "  Deleted: $($deletedGroups.Count)"
    Write-Verbose "  Unchanged: $($unchangedGroups.Count)"
    #endregion

    #region Step 4: Write changes to Cosmos using output bindings
    $groupsToWrite = @()
    $groupsToWrite += $newGroups
    $groupsToWrite += $modifiedGroups
    $groupsToWrite += $deletedGroups

    if ($groupsToWrite.Count -gt 0 -or (-not $enableDelta)) {
        Write-Verbose "Preparing $($groupsToWrite.Count) changed groups for Cosmos (including $($deletedGroups.Count) deleted)..."

        # If delta disabled, write all groups
        if (-not $enableDelta) {
            $groupsToWrite = $currentGroups.Values
            Write-Verbose "Delta detection disabled - writing all $($groupsToWrite.Count) groups"
        }

        # Prepare documents
        $docsToWrite = @()
        foreach ($group in $groupsToWrite) {
            # Check if this is a deleted group
            $isDeleted = $deletedGroups | Where-Object { $_.objectId -eq $group.objectId }

            $doc = @{
                id = $group.objectId
                objectId = $group.objectId
                displayName = $group.displayName
                classification = $group.classification
                deletedDateTime = $group.deletedDateTime
                description = $group.description
                groupTypes = $group.groupTypes
                mailEnabled = $group.mailEnabled
                membershipRule = $group.membershipRule
                securityEnabled = $group.securityEnabled
                isAssignableToRole = $group.isAssignableToRole
                createdDateTime = $group.createdDateTime
                visibility = $group.visibility
                onPremisesSyncEnabled = $group.onPremisesSyncEnabled
                onPremisesSecurityIdentifier = $group.onPremisesSecurityIdentifier
                mail = $group.mail
                collectionTimestamp = $group.collectionTimestamp
                lastModified = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
            }

            # Add soft delete markers
            if ($isDeleted) {
                $doc['deleted'] = $true
                $doc['deletedTimestamp'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            else {
                $doc['deleted'] = $false
            }

            $docsToWrite += $doc
        }

        # Write using output binding
        Push-OutputBinding -Name groupsRawOut -Value $docsToWrite
        Write-Verbose "Queued $($docsToWrite.Count) groups to groups_raw container"
    }
    else {
        Write-Verbose "No changes detected - skipping group writes"
    }
    #endregion

    #region Step 5: Write change log using output binding
    if ($changeLog.Count -gt 0) {
        Write-Verbose "Queuing $($changeLog.Count) change events..."
        Push-OutputBinding -Name groupChangesOut -Value $changeLog
        Write-Verbose "Queued $($changeLog.Count) change events to group_changes container"
    }
    #endregion

    #region Step 6: Write snapshot summary using output binding
    $snapshotDoc = @{
        id = $timestamp
        snapshotId = $timestamp
        collectionTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'groups'
        totalGroups = $currentGroups.Count
        newGroups = $newGroups.Count
        modifiedGroups = $modifiedGroups.Count
        deletedGroups = $deletedGroups.Count
        unchangedGroups = $unchangedGroups.Count
        cosmosWriteCount = $groupsToWrite.Count
        blobPath = $blobName
        deltaDetectionEnabled = $enableDelta
    }

    Push-OutputBinding -Name snapshotsOut -Value $snapshotDoc
    Write-Verbose "Queued snapshot summary to snapshots container"
    #endregion

    Write-Verbose "Cosmos DB indexing complete!"

    return @{
        Success = $true
        TotalGroups = $currentGroups.Count
        NewGroups = $newGroups.Count
        ModifiedGroups = $modifiedGroups.Count
        DeletedGroups = $deletedGroups.Count
        UnchangedGroups = $unchangedGroups.Count
        CosmosWriteCount = $groupsToWrite.Count
        SnapshotId = $timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalGroups = 0
        NewGroups = 0
        ModifiedGroups = 0
        DeletedGroups = 0
        UnchangedGroups = 0
        CosmosWriteCount = 0
        SnapshotId = $timestamp
    }
}
