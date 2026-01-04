#region Index in Cosmos DB Activity - DELTA CHANGE DETECTION with Output Bindings
<#
.SYNOPSIS
    Indexes service principals in Cosmos DB with delta change detection using native bindings
.DESCRIPTION
    - Reads service principals from Blob Storage (JSONL format)
    - Uses Cosmos DB input binding to read existing service principals
    - Compares and identifies changes (with special array comparison)
    - Uses output bindings to write changes (no REST API auth needed)
    - Logs all changes to service_principal_changes container
    - Writes summary to snapshots container
#>
#endregion

param($ActivityInput, $servicePrincipalsRawIn)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
Import-Module $modulePath -Force -ErrorAction Stop

try {
    Write-Verbose "Starting Cosmos DB indexing with delta detection (output bindings)"

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $enableDelta = $env:ENABLE_DELTA_DETECTION -eq 'true'

    $timestamp = $ActivityInput.Timestamp
    $servicePrincipalCount = $ActivityInput.ServicePrincipalCount
    $blobName = $ActivityInput.BlobName

    Write-Verbose "Configuration:"
    Write-Verbose "  Blob: $blobName"
    Write-Verbose "  Service Principals: $servicePrincipalCount"
    Write-Verbose "  Delta detection: $enableDelta"

    # Get storage token (cached)
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    #region Step 1: Read service principals from Blob
    Write-Verbose "Reading service principals from Blob Storage..."

    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'AppendBlob'
    }

    $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $headers

    # Parse JSONL into HashMap
    $currentServicePrincipals = @{}
    $lineNumber = 0

    foreach ($line in ($blobContent -split "`n")) {
        $lineNumber++
        if ($line.Trim()) {
            try {
                $sp = $line | ConvertFrom-Json
                $currentServicePrincipals[$sp.objectId] = $sp
            }
            catch {
                Write-Warning "Failed to parse line $lineNumber`: $_"
            }
        }
    }

    Write-Verbose "Parsed $($currentServicePrincipals.Count) service principals from Blob"
    #endregion

    #region Step 2: Read existing service principals from Cosmos (via input binding)
    $existingServicePrincipals = @{}

    if ($enableDelta -and $servicePrincipalsRawIn) {
        Write-Verbose "Reading existing service principals from Cosmos DB (input binding)..."

        foreach ($doc in $servicePrincipalsRawIn) {
            $existingServicePrincipals[$doc.objectId] = $doc
        }

        Write-Verbose "Found $($existingServicePrincipals.Count) existing service principals in Cosmos"
    }
    #endregion

    #region Step 3: Delta detection
    $newServicePrincipals = @()
    $modifiedServicePrincipals = @()
    $unchangedServicePrincipals = @()
    $deletedServicePrincipals = @()
    $changeLog = @()

    # Check current service principals
    foreach ($objectId in $currentServicePrincipals.Keys) {
        $currentSP = $currentServicePrincipals[$objectId]

        if (-not $existingServicePrincipals.ContainsKey($objectId)) {
            # NEW service principal
            $newServicePrincipals += $currentSP

            $changeLog += @{
                id = [Guid]::NewGuid().ToString()
                objectId = $objectId
                changeType = 'new'
                changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
                newValue = $currentSP
            }
        }
        else {
            # Check if modified
            $existingSP = $existingServicePrincipals[$objectId]

            $changed = $false
            $delta = @{}

            # Fields to compare: 8 scalar + 5 array
            $fieldsToCompare = @(
                'accountEnabled',
                'appRoleAssignmentRequired',
                'displayName',
                'appDisplayName',
                'servicePrincipalType',
                'description',
                'notes',
                'deletedDateTime',
                'addIns',
                'oauth2PermissionScopes',
                'resourceSpecificApplicationPermissions',
                'servicePrincipalNames',
                'tags'
            )

            foreach ($field in $fieldsToCompare) {
                if ($field -in @('addIns', 'oauth2PermissionScopes', 'resourceSpecificApplicationPermissions', 'servicePrincipalNames', 'tags')) {
                    # Special handling for array comparison
                    $currentArray = $currentSP.$field | Sort-Object
                    $existingArray = $existingSP.$field | Sort-Object

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
                    # Standard scalar comparison
                    $currentValue = $currentSP.$field
                    $existingValue = $existingSP.$field

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
                # MODIFIED service principal
                $modifiedServicePrincipals += $currentSP

                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'modified'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingSP
                    newValue = $currentSP
                    delta = $delta
                }
            }
            else {
                # UNCHANGED
                $unchangedServicePrincipals += $objectId
            }
        }
    }

    # Check for deleted service principals
    if ($enableDelta) {
        foreach ($objectId in $existingServicePrincipals.Keys) {
            if (-not $currentServicePrincipals.ContainsKey($objectId)) {
                # DELETED service principal
                $deletedServicePrincipals += $existingServicePrincipals[$objectId]

                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'deleted'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingServicePrincipals[$objectId]
                }
            }
        }
    }

    Write-Verbose "Delta summary:"
    Write-Verbose "  New: $($newServicePrincipals.Count)"
    Write-Verbose "  Modified: $($modifiedServicePrincipals.Count)"
    Write-Verbose "  Deleted: $($deletedServicePrincipals.Count)"
    Write-Verbose "  Unchanged: $($unchangedServicePrincipals.Count)"
    #endregion

    #region Step 4: Write changes to Cosmos using output bindings
    $servicePrincipalsToWrite = @()
    $servicePrincipalsToWrite += $newServicePrincipals
    $servicePrincipalsToWrite += $modifiedServicePrincipals

    if ($servicePrincipalsToWrite.Count -gt 0 -or (-not $enableDelta)) {
        Write-Verbose "Preparing $($servicePrincipalsToWrite.Count) changed service principals for Cosmos..."

        # If delta disabled, write all service principals
        if (-not $enableDelta) {
            $servicePrincipalsToWrite = $currentServicePrincipals.Values
            Write-Verbose "Delta detection disabled - writing all $($servicePrincipalsToWrite.Count) service principals"
        }

        # Prepare documents
        $docsToWrite = @()
        foreach ($sp in $servicePrincipalsToWrite) {
            $docsToWrite += @{
                id = $sp.objectId
                objectId = $sp.objectId
                appId = $sp.appId
                displayName = $sp.displayName
                appDisplayName = $sp.appDisplayName
                servicePrincipalType = $sp.servicePrincipalType
                accountEnabled = $sp.accountEnabled
                appRoleAssignmentRequired = $sp.appRoleAssignmentRequired
                deletedDateTime = $sp.deletedDateTime
                description = $sp.description
                notes = $sp.notes
                addIns = $sp.addIns
                oauth2PermissionScopes = $sp.oauth2PermissionScopes
                resourceSpecificApplicationPermissions = $sp.resourceSpecificApplicationPermissions
                servicePrincipalNames = $sp.servicePrincipalNames
                tags = $sp.tags
                collectionTimestamp = $sp.collectionTimestamp
                lastModified = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
            }
        }

        # Write using output binding
        Push-OutputBinding -Name servicePrincipalsRawOut -Value $docsToWrite
        Write-Verbose "Queued $($docsToWrite.Count) service principals to service_principals_raw container"
    }
    else {
        Write-Verbose "No changes detected - skipping service principal writes"
    }
    #endregion

    #region Step 5: Write change log using output binding
    if ($changeLog.Count -gt 0) {
        Write-Verbose "Queuing $($changeLog.Count) change events..."
        Push-OutputBinding -Name servicePrincipalChangesOut -Value $changeLog
        Write-Verbose "Queued $($changeLog.Count) change events to service_principal_changes container"
    }
    #endregion

    #region Step 6: Write snapshot summary using output binding
    $snapshotDoc = @{
        id = $timestamp
        snapshotId = $timestamp
        collectionTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'servicePrincipals'
        totalServicePrincipals = $currentServicePrincipals.Count
        newServicePrincipals = $newServicePrincipals.Count
        modifiedServicePrincipals = $modifiedServicePrincipals.Count
        deletedServicePrincipals = $deletedServicePrincipals.Count
        unchangedServicePrincipals = $unchangedServicePrincipals.Count
        cosmosWriteCount = $servicePrincipalsToWrite.Count
        blobPath = $blobName
        deltaDetectionEnabled = $enableDelta
    }

    Push-OutputBinding -Name snapshotsOut -Value $snapshotDoc
    Write-Verbose "Queued snapshot summary to snapshots container"
    #endregion

    Write-Verbose "Cosmos DB indexing complete!"

    return @{
        Success = $true
        TotalServicePrincipals = $currentServicePrincipals.Count
        NewServicePrincipals = $newServicePrincipals.Count
        ModifiedServicePrincipals = $modifiedServicePrincipals.Count
        DeletedServicePrincipals = $deletedServicePrincipals.Count
        UnchangedServicePrincipals = $unchangedServicePrincipals.Count
        CosmosWriteCount = $servicePrincipalsToWrite.Count
        SnapshotId = $timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
        TotalServicePrincipals = 0
        NewServicePrincipals = 0
        ModifiedServicePrincipals = 0
        DeletedServicePrincipals = 0
        UnchangedServicePrincipals = 0
        CosmosWriteCount = 0
        SnapshotId = $timestamp
    }
}
