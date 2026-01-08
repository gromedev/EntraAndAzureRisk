<#
.SYNOPSIS
    Collects Azure Automation Account data with managed identity information.
    V3 Architecture: Unified resources and edges containers.
.DESCRIPTION
    Phase 3 collector for Automation Accounts to enable lateral movement and execution attack path analysis.

    Collects:
    - Automation Account metadata (state, sku, creationTime)
    - System-assigned managed identity info
    - User-assigned managed identity info
    - Security settings (publicNetworkAccess, disableLocalAuth)
    - Contains relationships from RGs to Automation Accounts
    - hasManagedIdentity relationships linking Automation Accounts to SPs

    All output goes to azureresources.jsonl with resourceType = "automationAccount".
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
    Write-Verbose "Starting Automation Account collection"

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
        AutomationAccounts = 0
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

    #region 2. Collect Automation Accounts from each subscription
    foreach ($sub in $subscriptions) {
        $subscriptionId = $sub.subscriptionId
        Write-Verbose "Scanning subscription: $($sub.displayName) ($subscriptionId)"

        try {
            $aaUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Automation/automationAccounts?api-version=2023-11-01"
            $aaResponse = Invoke-RestMethod -Uri $aaUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($aa in $aaResponse.value) {
                $aaId = $aa.id ?? ""
                $aaName = $aa.name ?? ""

                # Parse resource group from ID
                $rgMatch = $aaId -match '/resourceGroups/([^/]+)/'
                $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                $props = $aa.properties

                # Identity info
                $identity = $aa.identity
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

                $aaObj = @{
                    id = $aaId
                    objectId = $aaId
                    resourceType = "automationAccount"
                    name = $aaName
                    displayName = $aaName
                    location = $aa.location ?? ""
                    subscriptionId = $subscriptionId
                    resourceGroupName = $rgName
                    resourceGroupId = $rgId

                    # State and SKU
                    state = $props.state ?? ""
                    sku = $props.sku.name ?? ""
                    creationTime = $props.creationTime ?? $null
                    lastModifiedTime = $props.lastModifiedTime ?? $null

                    # Security settings
                    publicNetworkAccess = if ($null -ne $props.publicNetworkAccess) { $props.publicNetworkAccess } else { $true }
                    disableLocalAuth = if ($null -ne $props.disableLocalAuth) { $props.disableLocalAuth } else { $false }

                    # Identity
                    identityType = $identity.type ?? "None"
                    hasSystemAssignedIdentity = $hasSystemAssigned
                    systemAssignedPrincipalId = $systemAssignedPrincipalId
                    systemAssignedTenantId = $identity.tenantId ?? $null
                    hasUserAssignedIdentity = $hasUserAssigned
                    userAssignedIdentities = $userAssignedIdentities
                    userAssignedIdentityCount = $userAssignedIdentities.Count

                    tags = $aa.tags ?? @{}
                    collectionTimestamp = $timestampFormatted
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                }

                [void]$resourcesJsonL.AppendLine(($aaObj | ConvertTo-Json -Compress -Depth 10))
                $stats.AutomationAccounts++

                # Create contains relationship from RG to Automation Account
                if ($rgId) {
                    $containsRel = @{
                        id = "$($rgId)_$($aaId)_contains"
                        objectId = "$($rgId)_$($aaId)_contains"
                        edgeType = "contains"
                        sourceId = $rgId
                        sourceType = "resourceGroup"
                        sourceDisplayName = $rgName
                        targetId = $aaId
                        targetType = "automationAccount"
                        targetDisplayName = $aaName
                        targetLocation = $aaObj.location
                        collectionTimestamp = $timestampFormatted
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                    }
                    [void]$edgesJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }

                # Create hasManagedIdentity relationships
                if ($hasSystemAssigned -and $systemAssignedPrincipalId) {
                    $miRel = @{
                        id = "$($aaId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        objectId = "$($aaId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        edgeType = "hasManagedIdentity"
                        sourceId = $aaId
                        sourceType = "automationAccount"
                        sourceDisplayName = $aaName
                        targetId = $systemAssignedPrincipalId
                        targetType = "servicePrincipal"
                        identityType = "SystemAssigned"
                        collectionTimestamp = $timestampFormatted
                        effectiveFrom = $timestampFormatted
                        effectiveTo = $null
                    }
                    [void]$edgesJsonL.AppendLine(($miRel | ConvertTo-Json -Compress))
                    $stats.ManagedIdentityLinks++
                }

                foreach ($uai in $userAssignedIdentities) {
                    if ($uai.principalId) {
                        $miRel = @{
                            id = "$($aaId)_$($uai.principalId)_hasManagedIdentity"
                            objectId = "$($aaId)_$($uai.principalId)_hasManagedIdentity"
                            edgeType = "hasManagedIdentity"
                            sourceId = $aaId
                            sourceType = "automationAccount"
                            sourceDisplayName = $aaName
                            targetId = $uai.principalId
                            targetType = "servicePrincipal"
                            identityType = "UserAssigned"
                            userAssignedIdentityId = $uai.id
                            collectionTimestamp = $timestampFormatted
                            effectiveFrom = $timestampFormatted
                            effectiveTo = $null
                        }
                        [void]$edgesJsonL.AppendLine(($miRel | ConvertTo-Json -Compress))
                        $stats.ManagedIdentityLinks++
                    }
                }

                # Periodic flush
                if ($resourcesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$resourcesJsonL) @resourcesFlushParams }
                if ($edgesJsonL.Length -ge $writeThreshold) { Write-BlobBuffer -Buffer ([ref]$edgesJsonL) @edgesFlushParams }
            }
        }
        catch {
            Write-Warning "Failed to collect Automation Accounts for subscription $subscriptionId`: $_"
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

    Write-Verbose "Automation Account collection complete: $($stats.AutomationAccounts) accounts, $($stats.ManagedIdentityLinks) managed identity links"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        EdgesBlobName = $edgesBlobName
        AutomationAccountCount = $stats.AutomationAccounts
        ManagedIdentityLinkCount = $stats.ManagedIdentityLinks
        EdgeCount = $stats.ContainsRelationships + $stats.ManagedIdentityLinks

        Stats = @{
            AutomationAccounts = $stats.AutomationAccounts
            SystemAssignedIdentity = $stats.SystemAssignedIdentity
            UserAssignedIdentity = $stats.UserAssignedIdentity
            ManagedIdentityLinks = $stats.ManagedIdentityLinks
            ContainsRelationships = $stats.ContainsRelationships
        }

        Summary = @{
            timestamp = $timestampFormatted
            automationAccounts = $stats.AutomationAccounts
            systemAssignedIdentity = $stats.SystemAssignedIdentity
            userAssignedIdentity = $stats.UserAssignedIdentity
            managedIdentityLinks = $stats.ManagedIdentityLinks
        }
    }
}
catch {
    Write-Error "Automation Account collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
