<#
.SYNOPSIS
    Collects Azure resources across all subscriptions using configuration-driven approach
.DESCRIPTION
    V3.5 Consolidated Azure Resource Collector:
    - Configuration-driven via AzureResourceTypes.psd1
    - Collects all Azure resource types in a single activity
    - Creates resources.jsonl entries with resourceType discriminator
    - Creates edges.jsonl entries for contains and hasManagedIdentity relationships

    Resource Types Collected:
    - Key Vaults (with access policies)
    - Virtual Machines
    - Storage Accounts (public access risk detection)
    - AKS Clusters
    - Container Registries (admin user risk detection)
    - VM Scale Sets
    - Data Factory
    - Automation Accounts
    - Function Apps
    - Logic Apps
    - Web Apps

    Permissions: Reader role on subscriptions
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Verbose "Module imported successfully"
}
catch {
    return @{ Success = $false; Error = "Failed to import module: $($_.Exception.Message)" }
}
#endregion

#region Load Configuration
try {
    $configPath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\AzureResourceTypes.psd1"
    $config = Import-PowerShellDataFile -Path $configPath
    $resourceTypes = $config.ResourceTypes
    Write-Verbose "Loaded $($resourceTypes.Count) resource type configurations"
}
catch {
    return @{ Success = $false; Error = "Failed to load AzureResourceTypes.psd1: $($_.Exception.Message)" }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Azure Resources collection (consolidated)"

    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get tokens
    try {
        $armToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        return @{ Success = $false; Error = "Token acquisition failed: $($_.Exception.Message)" }
    }

    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $tenantId = $env:TENANT_ID

    # Initialize buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(4194304)  # 4MB
    $edgesJsonL = New-Object System.Text.StringBuilder(2097152)      # 2MB
    $writeThreshold = 500000

    # Stats tracking
    $stats = @{
        TotalResources = 0
        TotalEdges = 0
        ByType = @{}
        SecurityRisks = @{
            PublicBlobAccess = 0
            AdminUserEnabled = 0
            NoPrivateCluster = 0
        }
    }

    # Initialize blobs
    $resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
    $edgesBlobName = "$timestamp/$timestamp-edges.jsonl"

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
        return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
    }

    # Flush helper
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

    #region Get Subscriptions
    Write-Verbose "Getting subscriptions..."
    $subsUri = "https://management.azure.com/subscriptions?api-version=2022-12-01"
    $subsResponse = Invoke-RestMethod -Uri $subsUri -Method GET -Headers $headers -ErrorAction Stop
    $subscriptions = $subsResponse.value
    Write-Verbose "Found $($subscriptions.Count) subscriptions"
    #endregion

    #region Collect Resources by Type
    foreach ($resourceType in $resourceTypes) {
        $typeName = $resourceType.Type
        $provider = $resourceType.Provider
        $apiVersion = $resourceType.ApiVersion
        $filter = $resourceType.Filter
        # Note: HasManagedIdentity and HasAccessPolicies are checked dynamically per resource

        Write-Verbose "Collecting $typeName resources..."
        $stats.ByType[$typeName] = 0

        foreach ($sub in $subscriptions) {
            $subscriptionId = $sub.subscriptionId

            try {
                # Build URI
                $resourceUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/$provider`?api-version=$apiVersion"
                if ($filter) {
                    $resourceUri += "&`$filter=$filter"
                }

                $resourceResponse = Invoke-RestMethod -Uri $resourceUri -Method GET -Headers $headers -ErrorAction Stop

                foreach ($resource in $resourceResponse.value) {
                    $resourceId = $resource.id ?? ""
                    $resourceName = $resource.name ?? ""
                    $props = $resource.properties

                    # Parse resource group from ID
                    $rgMatch = $resourceId -match '/resourceGroups/([^/]+)/'
                    $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                    $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                    # Build base resource object
                    $resourceObj = @{
                        id = $resourceId
                        objectId = $resourceId
                        resourceType = $typeName
                        name = $resourceName
                        displayName = $resourceName
                        location = $resource.location ?? ""
                        subscriptionId = $subscriptionId
                        resourceGroupName = $rgName
                        resourceGroupId = $rgId
                        tenantId = $tenantId
                        tags = $resource.tags ?? @{}
                        sku = $resource.sku ?? $null
                        kind = $resource.kind ?? $null
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                        collectionTimestamp = $timestampFormatted
                    }

                    # Extract managed identity if present
                    if ($resource.identity) {
                        $resourceObj.identity = @{
                            type = $resource.identity.type ?? ""
                            principalId = $resource.identity.principalId ?? $null
                            tenantId = $resource.identity.tenantId ?? $null
                            userAssignedIdentities = if ($resource.identity.userAssignedIdentities) {
                                $resource.identity.userAssignedIdentities.PSObject.Properties.Name
                            } else { @() }
                        }
                        $resourceObj.hasManagedIdentity = $true
                        $resourceObj.managedIdentityPrincipalId = $resource.identity.principalId ?? $null
                    } else {
                        $resourceObj.hasManagedIdentity = $false
                    }

                    # Extract security-relevant fields based on resource type
                    switch ($typeName) {
                        'keyVault' {
                            $resourceObj.vaultUri = $props.vaultUri ?? ""
                            $resourceObj.enableRbacAuthorization = $props.enableRbacAuthorization ?? $false
                            $resourceObj.enableSoftDelete = $props.enableSoftDelete ?? $true
                            $resourceObj.enablePurgeProtection = $props.enablePurgeProtection ?? $false
                            $resourceObj.softDeleteRetentionInDays = $props.softDeleteRetentionInDays ?? 90
                            $resourceObj.publicNetworkAccess = $props.publicNetworkAccess ?? ""

                            # Access policies (if not RBAC)
                            if (-not $resourceObj.enableRbacAuthorization -and $props.accessPolicies) {
                                $resourceObj.accessPolicyCount = $props.accessPolicies.Count
                            }
                        }
                        'storageAccount' {
                            $resourceObj.allowBlobPublicAccess = $props.allowBlobPublicAccess ?? $false
                            $resourceObj.minimumTlsVersion = $props.minimumTlsVersion ?? ""
                            $resourceObj.supportsHttpsTrafficOnly = $props.supportsHttpsTrafficOnly ?? $true
                            $resourceObj.publicNetworkAccess = $props.publicNetworkAccess ?? ""
                            $resourceObj.primaryEndpoints = $props.primaryEndpoints ?? $null

                            # Track security risk
                            if ($resourceObj.allowBlobPublicAccess -eq $true) {
                                $stats.SecurityRisks.PublicBlobAccess++
                            }
                        }
                        'aksCluster' {
                            $resourceObj.kubernetesVersion = $props.kubernetesVersion ?? ""
                            $resourceObj.enablePrivateCluster = $props.apiServerAccessProfile.enablePrivateCluster ?? $false
                            $resourceObj.disableLocalAccounts = $props.disableLocalAccounts ?? $false
                            $resourceObj.enableAzureRBAC = $props.aadProfile.enableAzureRBAC ?? $false
                            $resourceObj.aadEnabled = ($null -ne $props.aadProfile)
                            $resourceObj.networkPlugin = $props.networkProfile.networkPlugin ?? ""
                            $resourceObj.nodeCount = ($props.agentPoolProfiles | Measure-Object -Property count -Sum).Sum

                            if ($resourceObj.enablePrivateCluster -eq $false) {
                                $stats.SecurityRisks.NoPrivateCluster++
                            }
                        }
                        'containerRegistry' {
                            $resourceObj.adminUserEnabled = $props.adminUserEnabled ?? $false
                            $resourceObj.publicNetworkAccess = $props.publicNetworkAccess ?? ""
                            $resourceObj.loginServer = $props.loginServer ?? ""

                            if ($resourceObj.adminUserEnabled -eq $true) {
                                $stats.SecurityRisks.AdminUserEnabled++
                            }
                        }
                        'vmScaleSet' {
                            $resourceObj.upgradePolicy = $resource.properties.upgradePolicy.mode ?? ""
                            $resourceObj.capacity = $resource.sku.capacity ?? 0
                        }
                        'virtualMachine' {
                            $resourceObj.vmSize = $props.hardwareProfile.vmSize ?? ""
                            $resourceObj.osType = $props.storageProfile.osDisk.osType ?? ""
                            $resourceObj.provisioningState = $props.provisioningState ?? ""
                        }
                        'dataFactory' {
                            $resourceObj.publicNetworkAccess = $props.publicNetworkAccess ?? ""
                            $resourceObj.repoConfiguration = if ($props.repoConfiguration) { $true } else { $false }
                        }
                        'automationAccount' {
                            $resourceObj.publicNetworkAccess = $props.publicNetworkAccess ?? $true
                            $resourceObj.disableLocalAuth = $props.disableLocalAuth ?? $false
                        }
                        { $_ -in 'functionApp', 'webApp' } {
                            $resourceObj.httpsOnly = $props.httpsOnly ?? $false
                            $resourceObj.clientCertEnabled = $props.clientCertEnabled ?? $false
                            $resourceObj.state = $props.state ?? ""
                            $resourceObj.defaultHostName = $props.defaultHostName ?? ""
                        }
                        'logicApp' {
                            $resourceObj.state = $props.state ?? ""
                            $resourceObj.version = $props.version ?? ""
                        }
                    }

                    [void]$resourcesJsonL.AppendLine(($resourceObj | ConvertTo-Json -Compress -Depth 10))
                    $stats.ByType[$typeName]++
                    $stats.TotalResources++

                    # Create contains edge (RG → resource)
                    if ($rgId) {
                        $containsEdge = @{
                            id = "$($rgId)_$($resourceId)_contains"
                            objectId = "$($rgId)_$($resourceId)_contains"
                            edgeType = "contains"
                            sourceId = $rgId
                            sourceType = "resourceGroup"
                            sourceDisplayName = $rgName
                            targetId = $resourceId
                            targetType = $typeName
                            targetDisplayName = $resourceName
                            targetLocation = $resourceObj.location
                            effectiveFrom = $timestampFormatted
                            effectiveTo = $null
                            collectionTimestamp = $timestampFormatted
                        }
                        [void]$edgesJsonL.AppendLine(($containsEdge | ConvertTo-Json -Compress))
                        $stats.TotalEdges++
                    }

                    # Create hasManagedIdentity edge if applicable
                    if ($resourceObj.hasManagedIdentity -and $resourceObj.managedIdentityPrincipalId) {
                        $miEdge = @{
                            id = "$($resourceId)_$($resourceObj.managedIdentityPrincipalId)_hasManagedIdentity"
                            objectId = "$($resourceId)_$($resourceObj.managedIdentityPrincipalId)_hasManagedIdentity"
                            edgeType = "hasManagedIdentity"
                            sourceId = $resourceId
                            sourceType = $typeName
                            sourceDisplayName = $resourceName
                            targetId = $resourceObj.managedIdentityPrincipalId
                            targetType = "servicePrincipal"
                            identityType = $resourceObj.identity.type
                            effectiveFrom = $timestampFormatted
                            effectiveTo = $null
                            collectionTimestamp = $timestampFormatted
                        }
                        [void]$edgesJsonL.AppendLine(($miEdge | ConvertTo-Json -Compress))
                        $stats.TotalEdges++
                    }

                    # Periodic flush
                    if ($resourcesJsonL.Length -ge $writeThreshold) {
                        Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams
                    }
                    if ($edgesJsonL.Length -ge $writeThreshold) {
                        Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams
                    }
                }
            }
            catch {
                Write-Warning "Failed to collect $typeName for subscription $subscriptionId`: $_"
            }
        }

        Write-Verbose "  $typeName`: $($stats.ByType[$typeName]) resources"
    }
    #endregion

    # Final flush
    Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams
    Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams

    # Cleanup
    $resourcesJsonL.Clear()
    $resourcesJsonL = $null
    $edgesJsonL.Clear()
    $edgesJsonL = $null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Verbose "Azure Resources collection complete: $($stats.TotalResources) resources, $($stats.TotalEdges) edges"
    Write-Verbose "Security Risks: PublicBlob=$($stats.SecurityRisks.PublicBlobAccess), AdminUser=$($stats.SecurityRisks.AdminUserEnabled), NoPrivateAKS=$($stats.SecurityRisks.NoPrivateCluster)"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        EdgesBlobName = $edgesBlobName
        ResourceCount = $stats.TotalResources
        EdgeCount = $stats.TotalEdges
        Stats = $stats
        Summary = @{
            timestamp = $timestampFormatted
            totalResources = $stats.TotalResources
            totalEdges = $stats.TotalEdges
            byType = $stats.ByType
            securityRisks = $stats.SecurityRisks
        }
    }
}
catch {
    Write-Error "CollectAzureResources failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
