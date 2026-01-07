<#
.SYNOPSIS
    Collects Azure Web App data with managed identity information
.DESCRIPTION
    Phase 3 collector for Web Apps to enable lateral movement and execution attack path analysis.

    Collects:
    - Web App metadata (kind, state, httpsOnly, clientCertEnabled)
    - System-assigned managed identity info
    - User-assigned managed identity info
    - Host names and default host name
    - Contains relationships from RGs to Web Apps
    - hasManagedIdentity relationships linking Web Apps to SPs

    All output goes to azureresources.jsonl with resourceType = "webApp".
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
    Write-Verbose "Starting Web App collection"

    # Generate ISO 8601 timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
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
    $relationshipsJsonL = New-Object System.Text.StringBuilder(524288)
    $writeThreshold = 500000

    # Results tracking
    $stats = @{
        WebApps = 0
        SystemAssignedIdentity = 0
        UserAssignedIdentity = 0
        ManagedIdentityLinks = 0
        ContainsRelationships = 0
    }

    # Initialize append blobs
    $resourcesBlobName = "$timestamp/$timestamp-webapps.jsonl"
    $relationshipsBlobName = "$timestamp/$timestamp-webapp-relationships.jsonl"
    Write-Verbose "Initializing blobs: $resourcesBlobName, $relationshipsBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $resourcesBlobName `
                              -AccessToken $storageToken
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $relationshipsBlobName `
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
    $relationshipsFlushParams = @{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        BlobName = $relationshipsBlobName
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

    #region 2. Collect Web Apps from each subscription
    foreach ($sub in $subscriptions) {
        $subscriptionId = $sub.subscriptionId
        Write-Verbose "Scanning subscription: $($sub.displayName) ($subscriptionId)"

        try {
            # Get all web sites and filter for non-function apps
            $sitesUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Web/sites?api-version=2023-12-01"
            $sitesResponse = Invoke-RestMethod -Uri $sitesUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($site in $sitesResponse.value) {
                # Filter OUT function apps (kind contains 'functionapp')
                $kind = $site.kind ?? ""
                if ($kind -match 'functionapp') { continue }

                $siteId = $site.id ?? ""
                $siteName = $site.name ?? ""

                # Parse resource group from ID
                $rgMatch = $siteId -match '/resourceGroups/([^/]+)/'
                $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                $props = $site.properties

                # Identity info
                $identity = $site.identity
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

                $waObj = @{
                    id = $siteId
                    objectId = $siteId
                    resourceType = "webApp"
                    name = $siteName
                    displayName = $siteName
                    location = $site.location ?? ""
                    subscriptionId = $subscriptionId
                    resourceGroupName = $rgName
                    resourceGroupId = $rgId

                    # Kind and state
                    kind = $kind
                    state = $props.state ?? ""

                    # Security settings
                    httpsOnly = if ($null -ne $props.httpsOnly) { $props.httpsOnly } else { $false }
                    clientCertEnabled = if ($null -ne $props.clientCertEnabled) { $props.clientCertEnabled } else { $false }
                    clientCertMode = $props.clientCertMode ?? ""

                    # Host names
                    defaultHostName = $props.defaultHostName ?? ""
                    hostNames = $props.hostNames ?? @()
                    enabledHostNames = $props.enabledHostNames ?? @()

                    # App Service Plan
                    serverFarmId = $props.serverFarmId ?? ""

                    # Identity
                    identityType = $identity.type ?? "None"
                    hasSystemAssignedIdentity = $hasSystemAssigned
                    systemAssignedPrincipalId = $systemAssignedPrincipalId
                    systemAssignedTenantId = $identity.tenantId ?? $null
                    hasUserAssignedIdentity = $hasUserAssigned
                    userAssignedIdentities = $userAssignedIdentities
                    userAssignedIdentityCount = $userAssignedIdentities.Count

                    tags = $site.tags ?? @{}
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($waObj | ConvertTo-Json -Compress -Depth 10))
                $stats.WebApps++

                # Create contains relationship from RG to Web App
                if ($rgId) {
                    $containsRel = @{
                        id = "$($rgId)_$($siteId)_contains"
                        objectId = "$($rgId)_$($siteId)_contains"
                        relationType = "contains"
                        sourceId = $rgId
                        sourceType = "resourceGroup"
                        sourceDisplayName = $rgName
                        targetId = $siteId
                        targetType = "webApp"
                        targetDisplayName = $siteName
                        targetLocation = $waObj.location
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$relationshipsJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }

                # Create hasManagedIdentity relationships
                if ($hasSystemAssigned -and $systemAssignedPrincipalId) {
                    $miRel = @{
                        id = "$($siteId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        objectId = "$($siteId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        relationType = "hasManagedIdentity"
                        sourceId = $siteId
                        sourceType = "webApp"
                        sourceDisplayName = $siteName
                        targetId = $systemAssignedPrincipalId
                        targetType = "servicePrincipal"
                        identityType = "SystemAssigned"
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$relationshipsJsonL.AppendLine(($miRel | ConvertTo-Json -Compress))
                    $stats.ManagedIdentityLinks++
                }

                foreach ($uai in $userAssignedIdentities) {
                    if ($uai.principalId) {
                        $miRel = @{
                            id = "$($siteId)_$($uai.principalId)_hasManagedIdentity"
                            objectId = "$($siteId)_$($uai.principalId)_hasManagedIdentity"
                            relationType = "hasManagedIdentity"
                            sourceId = $siteId
                            sourceType = "webApp"
                            sourceDisplayName = $siteName
                            targetId = $uai.principalId
                            targetType = "servicePrincipal"
                            identityType = "UserAssigned"
                            userAssignedIdentityId = $uai.id
                            collectionTimestamp = $timestampFormatted
                        }
                        [void]$relationshipsJsonL.AppendLine(($miRel | ConvertTo-Json -Compress))
                        $stats.ManagedIdentityLinks++
                    }
                }

                # Periodic flush
                if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
                if ($relationshipsJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$relationshipsJsonL) @relationshipsFlushParams }
            }
        }
        catch {
            Write-Warning "Failed to collect Web Apps for subscription $subscriptionId`: $_"
        }
    }
    #endregion

    #region Final Flush
    Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams
    Write-BlobBuffer -Buffer ([ref]$relationshipsJsonL) @relationshipsFlushParams
    #endregion

    # Cleanup
    $resourcesJsonL.Clear()
    $resourcesJsonL = $null
    $relationshipsJsonL.Clear()
    $relationshipsJsonL = $null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Verbose "Web App collection complete: $($stats.WebApps) apps, $($stats.ManagedIdentityLinks) managed identity links"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        RelationshipsBlobName = $relationshipsBlobName
        WebAppCount = $stats.WebApps
        ManagedIdentityLinkCount = $stats.ManagedIdentityLinks
        RelationshipCount = $stats.ContainsRelationships + $stats.ManagedIdentityLinks

        Stats = $stats

        Summary = @{
            timestamp = $timestampFormatted
            webApps = $stats.WebApps
            systemAssignedIdentity = $stats.SystemAssignedIdentity
            userAssignedIdentity = $stats.UserAssignedIdentity
            managedIdentityLinks = $stats.ManagedIdentityLinks
        }
    }
}
catch {
    Write-Error "Web App collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
