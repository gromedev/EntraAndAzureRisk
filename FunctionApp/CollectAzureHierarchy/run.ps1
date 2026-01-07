<#
.SYNOPSIS
    Collects Azure resource hierarchy: Tenant, Management Groups, Subscriptions, Resource Groups
.DESCRIPTION
    Phase 2 collector for Azure resource hierarchy to enable attack path analysis.

    Collects:
    - Tenant info (from Graph API /organization)
    - Management Groups (from ARM API)
    - Subscriptions (from ARM API)
    - Resource Groups (from ARM API)
    - Contains relationships between hierarchy levels

    All output goes to azureresources.jsonl with resourceType discriminator.
    This enables unified indexing to the 'azureResources' container.
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
    Write-Verbose "Starting Azure hierarchy collection"

    # Generate ISO 8601 timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
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
    $tenantId = $env:TENANT_ID

    # Initialize buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial
    $relationshipsJsonL = New-Object System.Text.StringBuilder(524288)  # 512KB initial
    $writeThreshold = 500000

    # Results tracking
    $stats = @{
        Tenant = 0
        ManagementGroups = 0
        Subscriptions = 0
        ResourceGroups = 0
        ContainsRelationships = 0
    }

    # Initialize append blobs
    $resourcesBlobName = "$timestamp/$timestamp-azureresources.jsonl"
    $relationshipsBlobName = "$timestamp/$timestamp-azurerelationships.jsonl"
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

    # Splatting params for Write-BlobBuffer (consolidates Flush-*Buffer patterns)
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

    #region 1. Collect Tenant Info
    Write-Verbose "=== Phase 1: Collecting tenant info ==="

    try {
        $orgUri = "https://graph.microsoft.com/v1.0/organization"
        $orgResponse = Invoke-GraphWithRetry -Uri $orgUri -AccessToken $graphToken

        if ($orgResponse.value -and $orgResponse.value.Count -gt 0) {
            $org = $orgResponse.value[0]

            $tenantObj = @{
                id = $org.id
                objectId = $org.id
                resourceType = "tenant"
                displayName = $org.displayName ?? ""
                tenantId = $tenantId
                tenantType = $org.tenantType ?? ""
                defaultDomain = ($org.verifiedDomains | Where-Object { $_.isDefault } | Select-Object -First 1).name
                verifiedDomains = @($org.verifiedDomains | ForEach-Object {
                    @{
                        name = $_.name
                        type = $_.type
                        isDefault = $_.isDefault
                        isInitial = $_.isInitial
                    }
                })
                createdDateTime = $org.createdDateTime ?? $null
                city = $org.city ?? $null
                country = $org.country ?? $null
                state = $org.state ?? $null
                street = $org.street ?? $null
                postalCode = $org.postalCode ?? $null
                technicalNotificationMails = $org.technicalNotificationMails ?? @()
                securityComplianceNotificationMails = $org.securityComplianceNotificationMails ?? @()
                collectionTimestamp = $timestampFormatted
            }

            [void]$resourcesJsonL.AppendLine(($tenantObj | ConvertTo-Json -Compress -Depth 10))
            $stats.Tenant = 1
            Write-Verbose "Tenant collected: $($tenantObj.displayName)"
        }
    }
    catch {
        Write-Warning "Failed to collect tenant info: $_"
    }
    #endregion

    #region 2. Collect Management Groups
    Write-Verbose "=== Phase 2: Collecting management groups ==="

    $mgLookup = @{}  # For hierarchy building

    try {
        $mgUri = "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
        $headers = @{
            'Authorization' = "Bearer $armToken"
            'Content-Type' = 'application/json'
        }

        $mgResponse = Invoke-RestMethod -Uri $mgUri -Method GET -Headers $headers -ErrorAction Stop

        foreach ($mg in $mgResponse.value) {
            $mgId = $mg.id ?? ""
            $mgName = $mg.name ?? ""

            # Get full details including parent
            try {
                $mgDetailUri = "https://management.azure.com$($mg.id)?api-version=2021-04-01&`$expand=children,ancestors"
                $mgDetail = Invoke-RestMethod -Uri $mgDetailUri -Method GET -Headers $headers -ErrorAction Stop

                $parentId = $mgDetail.properties.details.parent.id ?? $null
                $parentName = $mgDetail.properties.details.parent.name ?? $null

                $mgObj = @{
                    id = $mgId
                    objectId = $mgId
                    resourceType = "managementGroup"
                    managementGroupId = $mgName
                    displayName = $mgDetail.properties.displayName ?? $mgName
                    tenantId = $mgDetail.properties.tenantId ?? $tenantId
                    parentId = $parentId
                    parentDisplayName = $parentName
                    childCount = ($mgDetail.properties.children ?? @()).Count
                    collectionTimestamp = $timestampFormatted
                }

                $mgLookup[$mgName] = $mgObj

                [void]$resourcesJsonL.AppendLine(($mgObj | ConvertTo-Json -Compress -Depth 10))
                $stats.ManagementGroups++

                # Create contains relationship if has parent
                if ($parentId) {
                    $containsRel = @{
                        id = "$($parentId)_$($mgId)_contains"
                        objectId = "$($parentId)_$($mgId)_contains"
                        relationType = "contains"
                        sourceId = $parentId
                        sourceType = if ($parentId -match '/managementGroups/') { "managementGroup" } else { "tenant" }
                        sourceDisplayName = $parentName ?? ""
                        targetId = $mgId
                        targetType = "managementGroup"
                        targetDisplayName = $mgObj.displayName
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$relationshipsJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }
            }
            catch {
                Write-Warning "Failed to get details for management group $mgName`: $_"
            }
        }

        Write-Verbose "Management groups collected: $($stats.ManagementGroups)"
    }
    catch {
        Write-Warning "Failed to collect management groups: $_"
    }
    #endregion

    # Periodic flush
    if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
    if ($relationshipsJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$relationshipsJsonL) @relationshipsFlushParams }

    #region 3. Collect Subscriptions
    Write-Verbose "=== Phase 3: Collecting subscriptions ==="

    $subscriptionLookup = @{}  # For resource group collection

    try {
        $subsUri = "https://management.azure.com/subscriptions?api-version=2022-12-01"
        $subsResponse = Invoke-RestMethod -Uri $subsUri -Method GET -Headers $headers -ErrorAction Stop

        foreach ($sub in $subsResponse.value) {
            $subId = $sub.id ?? ""
            $subscriptionId = $sub.subscriptionId ?? ""

            $subObj = @{
                id = $subId
                objectId = $subId
                resourceType = "subscription"
                subscriptionId = $subscriptionId
                displayName = $sub.displayName ?? ""
                state = $sub.state ?? ""
                tenantId = $sub.tenantId ?? $tenantId
                authorizationSource = $sub.authorizationSource ?? ""
                managedByTenants = $sub.managedByTenants ?? @()
                tags = $sub.tags ?? @{}
                collectionTimestamp = $timestampFormatted
            }

            $subscriptionLookup[$subscriptionId] = $subObj

            [void]$resourcesJsonL.AppendLine(($subObj | ConvertTo-Json -Compress -Depth 10))
            $stats.Subscriptions++

            # Get management group parent for subscription
            try {
                $subMgUri = "https://management.azure.com/providers/Microsoft.Management/getEntities?api-version=2021-04-01"
                $entitiesResponse = Invoke-RestMethod -Uri $subMgUri -Method POST -Headers $headers -ErrorAction SilentlyContinue

                # Find this subscription's parent MG
                $subEntity = $entitiesResponse.value | Where-Object { $_.name -eq $subscriptionId -and $_.type -eq '/subscriptions' }
                if ($subEntity -and $subEntity.properties.parent) {
                    $parentMgId = $subEntity.properties.parent.id
                    $parentMgName = $subEntity.properties.parent.name

                    $containsRel = @{
                        id = "$($parentMgId)_$($subId)_contains"
                        objectId = "$($parentMgId)_$($subId)_contains"
                        relationType = "contains"
                        sourceId = $parentMgId
                        sourceType = "managementGroup"
                        sourceDisplayName = $parentMgName ?? ""
                        targetId = $subId
                        targetType = "subscription"
                        targetDisplayName = $subObj.displayName
                        targetSubscriptionId = $subscriptionId
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$relationshipsJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }
            }
            catch {
                # Non-critical - subscription may not be under a management group
                Write-Verbose "Could not determine parent MG for subscription $subscriptionId"
            }
        }

        Write-Verbose "Subscriptions collected: $($stats.Subscriptions)"
    }
    catch {
        Write-Warning "Failed to collect subscriptions: $_"
    }
    #endregion

    # Periodic flush
    if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
    if ($relationshipsJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$relationshipsJsonL) @relationshipsFlushParams }

    #region 4. Collect Resource Groups
    Write-Verbose "=== Phase 4: Collecting resource groups ==="

    foreach ($subscriptionId in $subscriptionLookup.Keys) {
        $subObj = $subscriptionLookup[$subscriptionId]

        try {
            $rgUri = "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups?api-version=2022-09-01"
            $rgResponse = Invoke-RestMethod -Uri $rgUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($rg in $rgResponse.value) {
                $rgId = $rg.id ?? ""
                $rgName = $rg.name ?? ""

                $rgObj = @{
                    id = $rgId
                    objectId = $rgId
                    resourceType = "resourceGroup"
                    name = $rgName
                    displayName = $rgName
                    location = $rg.location ?? ""
                    subscriptionId = $subscriptionId
                    provisioningState = $rg.properties.provisioningState ?? ""
                    managedBy = $rg.managedBy ?? $null
                    tags = $rg.tags ?? @{}
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($rgObj | ConvertTo-Json -Compress -Depth 10))
                $stats.ResourceGroups++

                # Create contains relationship from subscription to RG
                $containsRel = @{
                    id = "$($subObj.id)_$($rgId)_contains"
                    objectId = "$($subObj.id)_$($rgId)_contains"
                    relationType = "contains"
                    sourceId = $subObj.id
                    sourceType = "subscription"
                    sourceDisplayName = $subObj.displayName
                    sourceSubscriptionId = $subscriptionId
                    targetId = $rgId
                    targetType = "resourceGroup"
                    targetDisplayName = $rgName
                    targetLocation = $rgObj.location
                    collectionTimestamp = $timestampFormatted
                }
                [void]$relationshipsJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                $stats.ContainsRelationships++
            }

            # Periodic flush during RG iteration
            if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
            if ($relationshipsJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$relationshipsJsonL) @relationshipsFlushParams }
        }
        catch {
            Write-Warning "Failed to collect resource groups for subscription $subscriptionId`: $_"
        }
    }

    Write-Verbose "Resource groups collected: $($stats.ResourceGroups)"
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

    $totalResources = $stats.Tenant + $stats.ManagementGroups + $stats.Subscriptions + $stats.ResourceGroups

    Write-Verbose "Azure hierarchy collection complete: $totalResources resources, $($stats.ContainsRelationships) contains relationships"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        RelationshipsBlobName = $relationshipsBlobName
        ResourceCount = $totalResources
        RelationshipCount = $stats.ContainsRelationships

        Stats = @{
            TenantCount = $stats.Tenant
            ManagementGroupCount = $stats.ManagementGroups
            SubscriptionCount = $stats.Subscriptions
            ResourceGroupCount = $stats.ResourceGroups
            ContainsRelationshipCount = $stats.ContainsRelationships
        }

        Summary = @{
            timestamp = $timestampFormatted
            tenant = $stats.Tenant
            managementGroups = $stats.ManagementGroups
            subscriptions = $stats.Subscriptions
            resourceGroups = $stats.ResourceGroups
            containsRelationships = $stats.ContainsRelationships
        }
    }
}
catch {
    Write-Error "Azure hierarchy collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
