<#
.SYNOPSIS
    Collects Azure Key Vault data with access policies and RBAC information
    V3 Architecture: Unified resources and edges containers
.DESCRIPTION
    Phase 2 collector for Key Vaults to enable secret access attack path analysis.

    Collects:
    - Key Vault metadata (SKU, soft delete settings, network rules)
    - Access policies (for non-RBAC vaults)
    - Secret/key/certificate counts
    - Contains relationships from RGs to Key Vaults
    - Access relationships for Key Vault permissions

    All output goes to azureresources.jsonl with resourceType = "keyVault".
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
    Write-Verbose "Starting Key Vault collection"

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
    $tenantId = $env:TENANT_ID

    # Initialize buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(1048576)
    $edgesJsonL = New-Object System.Text.StringBuilder(524288)
    $writeThreshold = 500000

    # Results tracking
    $stats = @{
        KeyVaults = 0
        RbacEnabled = 0
        AccessPolicyEnabled = 0
        SoftDeleteEnabled = 0
        PurgeProtectionEnabled = 0
        AccessPolicies = 0
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

    # Splatting params for Write-BlobBuffer (consolidates Flush-*Buffer patterns)
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

    #region 2. Collect Key Vaults from each subscription
    foreach ($sub in $subscriptions) {
        $subscriptionId = $sub.subscriptionId
        Write-Verbose "Scanning subscription: $($sub.displayName) ($subscriptionId)"

        try {
            $kvUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01"
            $kvResponse = Invoke-RestMethod -Uri $kvUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($kv in $kvResponse.value) {
                $kvId = $kv.id ?? ""
                $kvName = $kv.name ?? ""
                $props = $kv.properties

                # Parse resource group from ID
                $rgMatch = $kvId -match '/resourceGroups/([^/]+)/'
                $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                # Determine access model
                $enableRbacAuthorization = $props.enableRbacAuthorization ?? $false
                if ($enableRbacAuthorization) { $stats.RbacEnabled++ } else { $stats.AccessPolicyEnabled++ }

                # Track security features
                $enableSoftDelete = $props.enableSoftDelete ?? $true  # Default true since 2020
                $enablePurgeProtection = $props.enablePurgeProtection ?? $false
                if ($enableSoftDelete) { $stats.SoftDeleteEnabled++ }
                if ($enablePurgeProtection) { $stats.PurgeProtectionEnabled++ }

                # Process access policies
                $accessPolicies = @()
                if (-not $enableRbacAuthorization -and $props.accessPolicies) {
                    foreach ($policy in $props.accessPolicies) {
                        $policyObj = @{
                            tenantId = $policy.tenantId ?? ""
                            objectId = $policy.objectId ?? ""
                            applicationId = $policy.applicationId ?? $null
                            permissions = @{
                                keys = $policy.permissions.keys ?? @()
                                secrets = $policy.permissions.secrets ?? @()
                                certificates = $policy.permissions.certificates ?? @()
                                storage = $policy.permissions.storage ?? @()
                            }
                        }
                        $accessPolicies += $policyObj

                        # Create access relationship
                        $accessRel = @{
                            id = "$($policy.objectId)_$($kvId)_keyVaultAccess"
                            objectId = "$($policy.objectId)_$($kvId)_keyVaultAccess"
                            edgeType = "keyVaultAccess"
                            sourceId = $policy.objectId ?? ""
                            sourceType = "principal"  # Could be user, group, or SP
                            targetId = $kvId
                            targetType = "keyVault"
                            targetDisplayName = $kvName
                            accessType = "accessPolicy"
                            keyPermissions = $policy.permissions.keys ?? @()
                            secretPermissions = $policy.permissions.secrets ?? @()
                            certificatePermissions = $policy.permissions.certificates ?? @()
                            storagePermissions = $policy.permissions.storage ?? @()
                            # Abuse capability flags
                            canGetSecrets = ($policy.permissions.secrets -contains 'get')
                            canListSecrets = ($policy.permissions.secrets -contains 'list')
                            canSetSecrets = ($policy.permissions.secrets -contains 'set')
                            canGetKeys = ($policy.permissions.keys -contains 'get')
                            canDecryptWithKey = (($policy.permissions.keys -contains 'get') -and ($policy.permissions.keys -contains 'unwrapKey'))
                            canGetCertificates = ($policy.permissions.certificates -contains 'get')
                            effectiveFrom = $timestampFormatted
                            effectiveTo = $null
                            collectionTimestamp = $timestampFormatted
                        }
                        [void]$edgesJsonL.AppendLine(($accessRel | ConvertTo-Json -Compress -Depth 5))
                        $stats.AccessPolicies++
                    }
                }

                # Network rules
                $networkAcls = $null
                if ($props.networkAcls) {
                    $networkAcls = @{
                        defaultAction = $props.networkAcls.defaultAction ?? ""
                        bypass = $props.networkAcls.bypass ?? ""
                        ipRules = @($props.networkAcls.ipRules | ForEach-Object { $_.value })
                        virtualNetworkRules = @($props.networkAcls.virtualNetworkRules | ForEach-Object { $_.id })
                    }
                }

                $kvObj = @{
                    id = $kvId
                    objectId = $kvId
                    resourceType = "keyVault"
                    name = $kvName
                    displayName = $kvName
                    location = $kv.location ?? ""
                    subscriptionId = $subscriptionId
                    resourceGroupName = $rgName
                    resourceGroupId = $rgId
                    tenantId = $props.tenantId ?? $tenantId
                    vaultUri = $props.vaultUri ?? ""

                    # Security configuration
                    sku = @{
                        family = $props.sku.family ?? ""
                        name = $props.sku.name ?? ""
                    }
                    enableRbacAuthorization = $enableRbacAuthorization
                    enableSoftDelete = $enableSoftDelete
                    enablePurgeProtection = $enablePurgeProtection
                    softDeleteRetentionInDays = $props.softDeleteRetentionInDays ?? 90

                    # Public network access
                    publicNetworkAccess = $props.publicNetworkAccess ?? ""
                    enabledForDeployment = $props.enabledForDeployment ?? $false
                    enabledForDiskEncryption = $props.enabledForDiskEncryption ?? $false
                    enabledForTemplateDeployment = $props.enabledForTemplateDeployment ?? $false

                    # Network rules
                    networkAcls = $networkAcls

                    # Access policies (if using access policy model)
                    accessPolicies = $accessPolicies
                    accessPolicyCount = $accessPolicies.Count

                    # Private endpoints
                    privateEndpointConnections = @($props.privateEndpointConnections | ForEach-Object {
                        @{
                            id = $_.id ?? ""
                            privateEndpointId = $_.properties.privateEndpoint.id ?? ""
                            status = $_.properties.privateLinkServiceConnectionState.status ?? ""
                        }
                    })

                    tags = $kv.tags ?? @{}
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($kvObj | ConvertTo-Json -Compress -Depth 10))
                $stats.KeyVaults++

                # Create contains relationship from RG to Key Vault
                if ($rgId) {
                    $containsRel = @{
                        id = "$($rgId)_$($kvId)_contains"
                        objectId = "$($rgId)_$($kvId)_contains"
                        edgeType = "contains"
                        sourceId = $rgId
                        sourceType = "resourceGroup"
                        sourceDisplayName = $rgName
                        targetId = $kvId
                        targetType = "keyVault"
                        targetDisplayName = $kvName
                        targetLocation = $kvObj.location
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$edgesJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }

                # Periodic flush
                if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
                if ($edgesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams }
            }
        }
        catch {
            Write-Warning "Failed to collect Key Vaults for subscription $subscriptionId`: $_"
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

    Write-Verbose "Key Vault collection complete: $($stats.KeyVaults) vaults, $($stats.AccessPolicies) access policies"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        EdgesBlobName = $edgesBlobName
        KeyVaultCount = $stats.KeyVaults
        AccessPolicyCount = $stats.AccessPolicies
        EdgeCount = $stats.ContainsRelationships + $stats.AccessPolicies

        Stats = @{
            KeyVaults = $stats.KeyVaults
            RbacEnabled = $stats.RbacEnabled
            AccessPolicyEnabled = $stats.AccessPolicyEnabled
            SoftDeleteEnabled = $stats.SoftDeleteEnabled
            PurgeProtectionEnabled = $stats.PurgeProtectionEnabled
            AccessPolicies = $stats.AccessPolicies
            ContainsRelationships = $stats.ContainsRelationships
        }

        Summary = @{
            timestamp = $timestampFormatted
            keyVaults = $stats.KeyVaults
            rbacEnabled = $stats.RbacEnabled
            accessPolicyEnabled = $stats.AccessPolicyEnabled
            softDeleteEnabled = $stats.SoftDeleteEnabled
            purgeProtectionEnabled = $stats.PurgeProtectionEnabled
            accessPolicies = $stats.AccessPolicies
        }
    }
}
catch {
    Write-Error "Key Vault collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
