<#
.SYNOPSIS
    Projects entity changes from Cosmos DB audit container to Gremlin graph
.DESCRIPTION
    V3.1 Architecture: Timer-triggered function that syncs the Gremlin graph
    - Runs every 15 minutes
    - Reads changes from audit container since last sync
    - Projects vertices (principals, resources) first
    - Projects edges (relationships) second
    - Handles creates, updates, and deletes
    - Maintains sync watermark in blob storage
#>

# Azure Functions runtime passes this parameter - used for schedule info but not explicitly referenced
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Timer', Justification = 'Required by Azure Functions runtime')]
param($Timer)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Verbose "Module imported successfully from: $modulePath"
}
catch {
    $errorMsg = "Failed to import EntraDataCollection module: $($_.Exception.Message)"
    Write-Error $errorMsg
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Validate Environment Variables
$requiredEnvVars = @{
    'COSMOS_DB_ENDPOINT' = 'Cosmos DB endpoint for audit data'
    'COSMOS_DB_DATABASE' = 'Cosmos DB database name'
    'COSMOS_GREMLIN_ENDPOINT' = 'Gremlin endpoint for graph projection'
    'COSMOS_GREMLIN_DATABASE' = 'Gremlin database name'
    'COSMOS_GREMLIN_CONTAINER' = 'Gremlin graph container name'
    'COSMOS_GREMLIN_KEY' = 'Gremlin API key'
    'STORAGE_ACCOUNT_NAME' = 'Storage account for watermark'
    'TENANT_ID' = 'Entra ID tenant ID'
}

$missingVars = @()
foreach ($varName in $requiredEnvVars.Keys) {
    if (-not (Get-Item "Env:$varName" -ErrorAction SilentlyContinue)) {
        $missingVars += "$varName ($($requiredEnvVars[$varName]))"
    }
}

if ($missingVars) {
    $errorMsg = "Missing required environment variables:`n" + ($missingVars -join "`n")
    Write-Warning $errorMsg
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Function Logic
try {
    Write-Information "Starting Gremlin graph projection" -InformationAction Continue
    $startTime = Get-Date

    # Get tokens
    $cosmosToken = Get-CachedManagedIdentityToken -Resource "https://cosmos.azure.com"
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
    $cosmosDatabase = $env:COSMOS_DB_DATABASE
    $tenantId = $env:TENANT_ID
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $watermarkBlobName = "gremlin-sync/last-sync-watermark.json"

    # Get Gremlin connection
    $gremlinConnection = Get-GremlinConnection

    # Read last sync watermark from blob storage
    $lastSyncTimestamp = $null
    try {
        $watermarkUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$watermarkBlobName"
        $headers = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version' = '2021-08-06'
        }
        $watermarkResponse = Invoke-RestMethod -Uri $watermarkUri -Method Get -Headers $headers -ErrorAction Stop
        $lastSyncTimestamp = $watermarkResponse.lastSyncTimestamp
        Write-Information "Last sync timestamp: $lastSyncTimestamp" -InformationAction Continue
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            # First run - sync from 24 hours ago
            $lastSyncTimestamp = (Get-Date).AddHours(-24).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            Write-Information "First run - syncing from: $lastSyncTimestamp" -InformationAction Continue
        }
        else {
            Write-Warning "Failed to read watermark: $_"
            $lastSyncTimestamp = (Get-Date).AddHours(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    # Initialize statistics
    $stats = @{
        VerticesAdded = 0
        VerticesModified = 0
        VerticesDeleted = 0
        EdgesAdded = 0
        EdgesModified = 0
        EdgesDeleted = 0
        TotalChangesProcessed = 0
        Errors = 0
    }

    # Query audit container for changes since last sync
    # Process in batches to avoid memory issues
    $batchSize = 500
    $processedCount = 0
    $hasMoreChanges = $true
    $currentWatermark = $lastSyncTimestamp

    while ($hasMoreChanges) {
        $auditQuery = @"
SELECT TOP $batchSize * FROM c
WHERE c.changeTimestamp > '$currentWatermark'
ORDER BY c.changeTimestamp ASC
"@

        $changes = [System.Collections.Generic.List[object]]::new()

        Get-CosmosDocument -Endpoint $cosmosEndpoint -Database $cosmosDatabase `
            -Container 'audit' -Query $auditQuery -AccessToken $cosmosToken `
            -ProcessPage {
                param($Documents)
                foreach ($doc in $Documents) {
                    $changes.Add($doc)
                }
            }

        if ($changes.Count -eq 0) {
            $hasMoreChanges = $false
            Write-Information "No more changes to process" -InformationAction Continue
            continue
        }

        Write-Information "Processing batch of $($changes.Count) changes" -InformationAction Continue

        # Separate changes into vertex changes and edge changes
        # Process vertices first (they must exist before edges can reference them)
        $vertexChanges = @()
        $edgeChanges = @()

        foreach ($change in $changes) {
            $entityType = $change.entityType
            $isEdge = $entityType -in @('relationships', 'edges', 'azureRelationships')

            if ($isEdge) {
                $edgeChanges += $change
            }
            else {
                $vertexChanges += $change
            }

            # Update watermark to latest change
            if ($change.changeTimestamp -gt $currentWatermark) {
                $currentWatermark = $change.changeTimestamp
            }
        }

        # Process vertex changes first
        foreach ($change in $vertexChanges) {
            try {
                $changeType = $change.changeType
                $objectId = $change.objectId
                $displayName = $change.displayName ?? ""
                $principalType = $change.principalType ?? $change.entityType

                switch ($changeType) {
                    'new' {
                        $props = @{ displayName = $displayName }

                        # Add additional properties from delta if available
                        if ($change.delta) {
                            foreach ($field in $change.delta.Keys) {
                                $props[$field] = $change.delta[$field].new
                            }
                        }

                        Add-GraphVertex -ObjectId $objectId -Label $principalType `
                            -PartitionKey $tenantId -Properties $props `
                            -Connection $gremlinConnection
                        $stats.VerticesAdded++
                    }
                    'modified' {
                        $props = @{ displayName = $displayName }

                        # Apply delta changes
                        if ($change.delta) {
                            foreach ($field in $change.delta.Keys) {
                                $props[$field] = $change.delta[$field].new
                            }
                        }

                        Add-GraphVertex -ObjectId $objectId -Label $principalType `
                            -PartitionKey $tenantId -Properties $props `
                            -Connection $gremlinConnection
                        $stats.VerticesModified++
                    }
                    'deleted' {
                        Remove-GraphVertex -ObjectId $objectId -Connection $gremlinConnection
                        $stats.VerticesDeleted++
                    }
                }
            }
            catch {
                Write-Warning "Failed to process vertex change $($change.id): $_"
                $stats.Errors++
            }
        }

        # Process edge changes second (after vertices exist)
        foreach ($change in $edgeChanges) {
            try {
                $changeType = $change.changeType

                # For edges, we need to parse the objectId or get source/target from the change
                # Edge objectId format: {sourceId}_{targetId}_{edgeType}
                $edgeParts = $change.objectId -split '_'

                if ($edgeParts.Count -ge 3) {
                    $sourceId = $edgeParts[0]
                    $targetId = $edgeParts[1]
                    $edgeType = $edgeParts[2..($edgeParts.Count - 1)] -join '_'

                    switch ($changeType) {
                        'new' {
                            $props = @{}
                            if ($change.delta) {
                                foreach ($field in $change.delta.Keys) {
                                    $props[$field] = $change.delta[$field].new
                                }
                            }

                            Add-GraphEdge -SourceId $sourceId -TargetId $targetId `
                                -EdgeType $edgeType -Properties $props `
                                -Connection $gremlinConnection
                            $stats.EdgesAdded++
                        }
                        'modified' {
                            $props = @{}
                            if ($change.delta) {
                                foreach ($field in $change.delta.Keys) {
                                    $props[$field] = $change.delta[$field].new
                                }
                            }

                            Add-GraphEdge -SourceId $sourceId -TargetId $targetId `
                                -EdgeType $edgeType -Properties $props `
                                -Connection $gremlinConnection
                            $stats.EdgesModified++
                        }
                        'deleted' {
                            Remove-GraphEdge -SourceId $sourceId -TargetId $targetId `
                                -EdgeType $edgeType -Connection $gremlinConnection
                            $stats.EdgesDeleted++
                        }
                    }
                }
                else {
                    Write-Warning "Invalid edge objectId format: $($change.objectId)"
                    $stats.Errors++
                }
            }
            catch {
                Write-Warning "Failed to process edge change $($change.id): $_"
                $stats.Errors++
            }
        }

        $processedCount += $changes.Count
        $stats.TotalChangesProcessed = $processedCount

        # If we got less than batch size, we're done
        if ($changes.Count -lt $batchSize) {
            $hasMoreChanges = $false
        }
    }

    # Save new watermark to blob storage
    $newWatermark = @{
        lastSyncTimestamp = $currentWatermark
        lastSyncTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        changesProcessed = $stats.TotalChangesProcessed
    } | ConvertTo-Json -Compress

    try {
        $watermarkUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$watermarkBlobName"
        $headers = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version' = '2021-08-06'
            'x-ms-blob-type' = 'BlockBlob'
            'Content-Type' = 'application/json'
        }
        Invoke-RestMethod -Uri $watermarkUri -Method Put -Headers $headers -Body $newWatermark | Out-Null
        Write-Information "Watermark updated: $currentWatermark" -InformationAction Continue
    }
    catch {
        Write-Warning "Failed to save watermark: $_"
    }

    # Calculate duration
    $duration = ((Get-Date) - $startTime).TotalSeconds

    Write-Information "Gremlin projection complete in $([Math]::Round($duration, 2))s" -InformationAction Continue
    Write-Information "  Vertices: +$($stats.VerticesAdded) ~$($stats.VerticesModified) -$($stats.VerticesDeleted)" -InformationAction Continue
    Write-Information "  Edges: +$($stats.EdgesAdded) ~$($stats.EdgesModified) -$($stats.EdgesDeleted)" -InformationAction Continue
    Write-Information "  Total changes: $($stats.TotalChangesProcessed), Errors: $($stats.Errors)" -InformationAction Continue

    return @{
        Success = $true
        DurationSeconds = $duration
        LastSyncTimestamp = $currentWatermark
        Statistics = $stats
    }
}
catch {
    Write-Error "Gremlin projection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
