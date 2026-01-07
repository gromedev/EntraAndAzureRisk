<#
.SYNOPSIS
    Collects Azure Virtual Machine data with managed identity information
.DESCRIPTION
    Phase 2 collector for VMs to enable lateral movement and execution attack path analysis.

    Collects:
    - VM metadata (size, OS, power state)
    - System-assigned managed identity info
    - User-assigned managed identity info
    - Network interface info
    - Contains relationships from RGs to VMs
    - hasManagedIdentity relationships linking VMs to SPs

    All output goes to azureresources.jsonl with resourceType = "virtualMachine".
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
    Write-Verbose "Starting Virtual Machine collection"

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
        VirtualMachines = 0
        WindowsVMs = 0
        LinuxVMs = 0
        RunningVMs = 0
        DeallocatedVMs = 0
        SystemAssignedIdentity = 0
        UserAssignedIdentity = 0
        ManagedIdentityLinks = 0
        ContainsRelationships = 0
    }

    # Initialize append blobs
    $resourcesBlobName = "$timestamp/$timestamp-virtualmachines.jsonl"
    $relationshipsBlobName = "$timestamp/$timestamp-vm-relationships.jsonl"
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

    #region 2. Collect VMs from each subscription
    foreach ($sub in $subscriptions) {
        $subscriptionId = $sub.subscriptionId
        Write-Verbose "Scanning subscription: $($sub.displayName) ($subscriptionId)"

        try {
            # Use statusOnly=true for power state, expand for instanceView
            $vmUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/virtualMachines?api-version=2024-03-01&statusOnly=true"
            $vmResponse = Invoke-RestMethod -Uri $vmUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($vm in $vmResponse.value) {
                $vmId = $vm.id ?? ""
                $vmName = $vm.name ?? ""

                # Parse resource group from ID
                $rgMatch = $vmId -match '/resourceGroups/([^/]+)/'
                $rgName = if ($rgMatch) { $Matches[1] } else { "" }
                $rgId = if ($rgName) { "/subscriptions/$subscriptionId/resourceGroups/$rgName" } else { "" }

                $props = $vm.properties

                # Get power state from instance view
                $powerState = "unknown"
                if ($props.instanceView -and $props.instanceView.statuses) {
                    $powerStatus = $props.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1
                    if ($powerStatus) {
                        $powerState = $powerStatus.code -replace 'PowerState/', ''
                    }
                }

                # Track stats
                if ($powerState -eq 'running') { $stats.RunningVMs++ }
                elseif ($powerState -eq 'deallocated') { $stats.DeallocatedVMs++ }

                # OS info
                $osType = "unknown"
                $osName = ""
                if ($props.storageProfile.osDisk.osType) {
                    $osType = $props.storageProfile.osDisk.osType
                }
                if ($props.storageProfile.imageReference) {
                    $imgRef = $props.storageProfile.imageReference
                    $osName = "$($imgRef.publisher ?? '') $($imgRef.offer ?? '') $($imgRef.sku ?? '')" -replace '^\s+|\s+$', ''
                }
                if ($osType -eq 'Windows') { $stats.WindowsVMs++ }
                elseif ($osType -eq 'Linux') { $stats.LinuxVMs++ }

                # Identity info
                $identity = $vm.identity
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

                # Network interfaces
                $networkInterfaces = @()
                if ($props.networkProfile -and $props.networkProfile.networkInterfaces) {
                    foreach ($nic in $props.networkProfile.networkInterfaces) {
                        $networkInterfaces += @{
                            id = $nic.id ?? ""
                            primary = $nic.properties.primary ?? $false
                        }
                    }
                }

                $vmObj = @{
                    id = $vmId
                    objectId = $vmId
                    resourceType = "virtualMachine"
                    vmId = $props.vmId ?? ""
                    name = $vmName
                    displayName = $vmName
                    location = $vm.location ?? ""
                    subscriptionId = $subscriptionId
                    resourceGroupName = $rgName
                    resourceGroupId = $rgId

                    # Hardware
                    vmSize = $props.hardwareProfile.vmSize ?? ""
                    zones = $vm.zones ?? @()

                    # OS
                    osType = $osType
                    osName = $osName
                    computerName = $props.osProfile.computerName ?? ""

                    # State
                    powerState = $powerState
                    provisioningState = $props.provisioningState ?? ""

                    # Identity
                    identityType = $identity.type ?? "None"
                    hasSystemAssignedIdentity = $hasSystemAssigned
                    systemAssignedPrincipalId = $systemAssignedPrincipalId
                    systemAssignedTenantId = $identity.tenantId ?? $null
                    hasUserAssignedIdentity = $hasUserAssigned
                    userAssignedIdentities = $userAssignedIdentities
                    userAssignedIdentityCount = $userAssignedIdentities.Count

                    # Network
                    networkInterfaces = $networkInterfaces
                    networkInterfaceCount = $networkInterfaces.Count

                    # Admin
                    adminUsername = $props.osProfile.adminUsername ?? $null
                    disablePasswordAuthentication = $props.osProfile.linuxConfiguration.disablePasswordAuthentication ?? $null

                    tags = $vm.tags ?? @{}
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($vmObj | ConvertTo-Json -Compress -Depth 10))
                $stats.VirtualMachines++

                # Create contains relationship from RG to VM
                if ($rgId) {
                    $containsRel = @{
                        id = "$($rgId)_$($vmId)_contains"
                        objectId = "$($rgId)_$($vmId)_contains"
                        relationType = "contains"
                        sourceId = $rgId
                        sourceType = "resourceGroup"
                        sourceDisplayName = $rgName
                        targetId = $vmId
                        targetType = "virtualMachine"
                        targetDisplayName = $vmName
                        targetLocation = $vmObj.location
                        collectionTimestamp = $timestampFormatted
                    }
                    [void]$relationshipsJsonL.AppendLine(($containsRel | ConvertTo-Json -Compress))
                    $stats.ContainsRelationships++
                }

                # Create hasManagedIdentity relationships
                if ($hasSystemAssigned -and $systemAssignedPrincipalId) {
                    $miRel = @{
                        id = "$($vmId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        objectId = "$($vmId)_$($systemAssignedPrincipalId)_hasManagedIdentity"
                        relationType = "hasManagedIdentity"
                        sourceId = $vmId
                        sourceType = "virtualMachine"
                        sourceDisplayName = $vmName
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
                            id = "$($vmId)_$($uai.principalId)_hasManagedIdentity"
                            objectId = "$($vmId)_$($uai.principalId)_hasManagedIdentity"
                            relationType = "hasManagedIdentity"
                            sourceId = $vmId
                            sourceType = "virtualMachine"
                            sourceDisplayName = $vmName
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
            Write-Warning "Failed to collect VMs for subscription $subscriptionId`: $_"
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

    Write-Verbose "VM collection complete: $($stats.VirtualMachines) VMs, $($stats.ManagedIdentityLinks) managed identity links"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        RelationshipsBlobName = $relationshipsBlobName
        VirtualMachineCount = $stats.VirtualMachines
        ManagedIdentityLinkCount = $stats.ManagedIdentityLinks
        RelationshipCount = $stats.ContainsRelationships + $stats.ManagedIdentityLinks

        Stats = @{
            VirtualMachines = $stats.VirtualMachines
            WindowsVMs = $stats.WindowsVMs
            LinuxVMs = $stats.LinuxVMs
            RunningVMs = $stats.RunningVMs
            DeallocatedVMs = $stats.DeallocatedVMs
            SystemAssignedIdentity = $stats.SystemAssignedIdentity
            UserAssignedIdentity = $stats.UserAssignedIdentity
            ManagedIdentityLinks = $stats.ManagedIdentityLinks
            ContainsRelationships = $stats.ContainsRelationships
        }

        Summary = @{
            timestamp = $timestampFormatted
            virtualMachines = $stats.VirtualMachines
            windowsVMs = $stats.WindowsVMs
            linuxVMs = $stats.LinuxVMs
            runningVMs = $stats.RunningVMs
            deallocatedVMs = $stats.DeallocatedVMs
            systemAssignedIdentity = $stats.SystemAssignedIdentity
            userAssignedIdentity = $stats.UserAssignedIdentity
            managedIdentityLinks = $stats.ManagedIdentityLinks
        }
    }
}
catch {
    Write-Error "Virtual Machine collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
