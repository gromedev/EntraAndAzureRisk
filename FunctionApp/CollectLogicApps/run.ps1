<#
.SYNOPSIS
    Collects Azure Logic App (Standard workflows) data with managed identity information.
    V3 Architecture: Unified resources and edges containers.
.DESCRIPTION
    Phase 3 collector for Logic Apps to enable lateral movement and execution attack path analysis.

    Collects:
    - Logic App metadata (state, accessEndpoint)
    - System-assigned managed identity info
    - User-assigned managed identity info
    - Definition info (trigger types, action count)
    - Contains relationships from RGs to Logic Apps
    - hasManagedIdentity relationships linking Logic Apps to SPs

    All output goes to azureresources.jsonl with resourceType = "logicApp".
#>

param($ActivityInput)

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
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
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
    Write-Verbose "Starting Logic App collection"

    # V3: Use shared timestamp from orchestrator (critical for unified blob files)
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $armToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{
            Success = $false
            Error = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Initialize buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(1048576)
    $edgesJsonL = New-Object System.Text.StringBuilder(524288)
    $writeThreshold = 500000

    # Results tracking
    $stats = @{
        LogicApps = 0
        EnabledApps = 0
        DisabledApps = 0
        SystemAssignedIdentity = 0
        UserAssignedIdentity = 0
        ManagedIdentityLinks = 0
        ContainsRelationships = 0
    }

    # Initialize append blobs
    $resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
    $edgesBlobName = "$timestamp/$timestamp-edges.jsonl"
    Write-Verbose "Initializing blobs: $resourcesBlobName, $edgesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $resourcesBlobName `
                              -AccessToken $storageToken
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $edgesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blobs: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Splatting params for Write-BlobBuffer
    $resourcesFlushParams = @{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        BlobName = $resourcesBlobName
        AccessToken = $storageToken
    }
    $edgesFlushParams = @{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        BlobName = $edgesBlobName
        AccessToken = $storageToken
    }

    $headers = @{
        'Authorization' = "Bearer $armToken"
        'Content-Type' = 'application/json'
    }

    #region 1. Get all subscriptions
    Write-Verbose "Getting subscriptions..."
    $subsUri = "https://management.azure.com/subscriptions?api-version=2022-12-01"
    $subsResponse = Invoke-RestMethod -Uri $subsUri -Method GET -Headers $headers -ErrorAction Stop
    $subscriptions = $subsResponse.value
    Write-Verbose "Found $($subscriptions.Count) subscriptions"
    #endregion

    #region 2. Collect Logic Apps from each subscription
    foreach ($sub in $subscriptions) {
        $subscriptionId = $sub.subscriptionId
        Write-Verbose "Scanning subscription: $($sub.displayName) ($subscriptionId)"

        try {
            $laUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Logic/workflows?api-version=2019-05-01"
            $laResponse = Invoke-RestMethod -Uri $laUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($la in $laResponse.value) {
                $laId = $la.id ?? ""
                $laName = $la.name ?? ""

                # Parse resource group from ID
                $rgMatch = $laId -match '/resourceGroups/([^/]+)/'
                $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                $props = $la.properties

                # Track stats
                $state = $props.state ?? ""
                if ($state -eq 'Enabled') { $stats.EnabledApps++ }
                elseif ($state -eq 'Disabled') { $stats.DisabledApps++ }

                # Identity info
                $identity = $la.identity
                $hasSystemAssigned = $false
                $hasUserAssigned = $false
                $systemAssignedPrincipalId = $null
                $userAssignedIdentities = @()

                if ($identity) {
                    if ($identity.type -match 'SystemAssigned') {
                        $hasSystemAssigned = $true
                        $systemAssignedPrincipalId = $identity.principalId
                        $stats.SystemAssignedIdentity++
                    }
                    if ($identity.type -match 'UserAssigned' -and $identity.userAssignedIdentities) {
                        $hasUserAssigned = $true
                        $stats.UserAssignedIdentity++
                        foreach ($uaiId in $identity.userAssignedIdentities.PSObject.Properties.Name) {
                            $uaiInfo = $identity.userAssignedIdentities.$uaiId
                            $userAssignedIdentities += @{
                                id = $uaiId
                                principalId = $uaiInfo.principalId ?? ""
                                clientId = $uaiInfo.clientId ?? ""
                            }
                        }
                    }
                }

                # Extract trigger type from definition
                $triggerType = "unknown"
                $actionCount = 0
                if ($props.definition -and $props.definition.triggers) {
                    $triggers = $props.definition.triggers.PSObject.Properties
                    if ($triggers.Count -gt 0) {
                        $firstTrigger = $triggers | Select-Object -First 1
                        $triggerType = $firstTrigger.Value.type ?? "unknown"
                    }
                }
                if ($props.definition -and $props.definition.actions) {
                    $actionCount = $props.definition.actions.PSObject.Properties.Count
                }

                $laObj = @{
                    id = $laId
                    objectId = $laId
                    resourceType = "logicApp"
                    name = $laName
                    displayName = $laName
                    location = $la.location ?? ""
                    subscriptionId = $subscriptionId
                    resourceGroupName = $rgName
                    resourceGroupId = $rgId

                    # State
                    state = $state
                    provisioningState = $props.provisioningState ?? ""
                    createdTime = $props.createdTime ?? $null
                    changedTime = $props.changedTime ?? $null

                    # Endpoints
                    accessEndpoint = $props.accessEndpoint ?? ""

                    # Definition info
                    triggerType = $triggerType
                    actionCount = $actionCount

                    # Identity
                    identityType = $identity.type ?? "None"
                    hasSystemAssignedIdentity = $hasSystemAssigned
                    systemAssignedPrincipalId = $systemAssignedPrincipalId
                    systemAssignedTenantId = $identity.tenantId ?? $null
                    hasUserAssignedIdentity = $hasUserAssigned
                    userAssignedIdentities = $userAssignedIdentities
                    userAssignedIdentityCount = $userAssignedIdentities.Count

                    tags = $la.tags ?? @{}
                    collectionTimestamp = $timestampFormatted
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                }

                [void]$resourcesJsonL.AppendLine(($laObj | ConvertTo-Json -Compress -Depth 10))
                $stats.LogicApps++

                # Create contains edge from RG to Logic App
                if ($rgId) {
                    $containsEdge = @{
                        id = "$($rgId)_$($laId)_contains"
                        objectId = "$($rgId)_$($laId)_contains"
                        edgeType = "contains"
                        sourceId = $rgId
                        sourceType = "resourceGroup"
                        sourceDisplayName = $rgName
                        targetId = $laId
                        targetType = "logicApp"
                        targetDisplayName = $laName
                        targetLocation = $laObj.location
                        collectionTimestamp = $timestampFormatted
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                    }
                    [void]$edgesJsonL.AppendLine(($containsEdge | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }

                # Create hasManagedIdentity edges
                if ($hasSystemAssigned -and $systemAssignedPrincipalId) {
                    $miEdge = @{
                        id = "$($laId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        objectId = "$($laId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        edgeType = "hasManagedIdentity"
                        sourceId = $laId
                        sourceType = "logicApp"
                        sourceDisplayName = $laName
                        targetId = $systemAssignedPrincipalId
                        targetType = "servicePrincipal"
                        identityType = "SystemAssigned"
                        collectionTimestamp = $timestampFormatted
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                    }
                    [void]$edgesJsonL.AppendLine(($miEdge | ConvertTo-Json -Compress))
                    $stats.ManagedIdentityLinks++
                }

                foreach ($uai in $userAssignedIdentities) {
                    if ($uai.principalId) {
                        $miEdge = @{
                            id = "$($laId)_$($uai.principalId)_hasManagedIdentity"
                            objectId = "$($laId)_$($uai.principalId)_hasManagedIdentity"
                            edgeType = "hasManagedIdentity"
                            sourceId = $laId
                            sourceType = "logicApp"
                            sourceDisplayName = $laName
                            targetId = $uai.principalId
                            targetType = "servicePrincipal"
                            identityType = "UserAssigned"
                            userAssignedIdentityId = $uai.id
                            collectionTimestamp = $timestampFormatted
                            effectiveFrom = $timestampFormatted
                            effectiveTo = $null
                        }
                        [void]$edgesJsonL.AppendLine(($miEdge | ConvertTo-Json -Compress))
                        $stats.ManagedIdentityLinks++
                    }
                }

                # Periodic flush
                if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
                if ($edgesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams }
            }
        }
        catch {
            Write-Warning "Failed to collect Logic Apps for subscription $subscriptionId`: $_"
        }
    }
    #endregion

    #region Final Flush
    Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams
    Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams
    #endregion

    # Cleanup
    $resourcesJsonL.Clear()
    $resourcesJsonL = $null
    $edgesJsonL.Clear()
    $edgesJsonL = $null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Verbose "Logic App collection complete: $($stats.LogicApps) apps, $($stats.ManagedIdentityLinks) managed identity links"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        EdgesBlobName = $edgesBlobName
        LogicAppCount = $stats.LogicApps
        ManagedIdentityLinkCount = $stats.ManagedIdentityLinks
        EdgeCount = $stats.ContainsRelationships + $stats.ManagedIdentityLinks

        Stats = $stats

        Summary = @{
            timestamp = $timestampFormatted
            logicApps = $stats.LogicApps
            enabledApps = $stats.EnabledApps
            disabledApps = $stats.DisabledApps
            systemAssignedIdentity = $stats.SystemAssignedIdentity
            userAssignedIdentity = $stats.UserAssignedIdentity
            managedIdentityLinks = $stats.ManagedIdentityLinks
        }
    }
}
catch {
    Write-Error "Logic App collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
