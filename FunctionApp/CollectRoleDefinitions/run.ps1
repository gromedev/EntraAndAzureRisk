<#
.SYNOPSIS
    Collects Role Definitions from both Entra ID and Azure Resource Manager
.DESCRIPTION
    V3.5 Consolidated Role Definitions Collector:
    - Directory Role Definitions (Graph API /roleManagement/directory/roleDefinitions)
    - Azure Role Definitions (ARM API /providers/Microsoft.Authorization/roleDefinitions)

    Outputs to resources.jsonl with:
    - resourceType="directoryRoleDefinition" for Entra ID roles
    - resourceType="azureRoleDefinition" for Azure RBAC roles

    Both include isPrivileged flag for privileged roles (attack path relevance).
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    return @{ Success = $false; Error = "Failed to import module: $($_.Exception.Message)" }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Role Definitions collection (Directory + Azure)"

    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get tokens
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        $armToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        return @{ Success = $false; Error = "Token acquisition failed: $($_.Exception.Message)" }
    }

    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Privileged Entra ID role template IDs
    $privilegedDirectoryRoles = @(
        '62e90394-69f5-4237-9190-012177145e10'  # Global Administrator
        'e8611ab8-c189-46e8-94e1-60213ab1f814'  # Privileged Role Administrator
        '194ae4cb-b126-40b2-bd5b-6091b380977d'  # Security Administrator
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'  # Application Administrator
        '158c047a-c907-4556-b7ef-446551a6b5f7'  # Cloud Application Administrator
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'  # Privileged Authentication Administrator
        'fe930be7-5e62-47db-91af-98c3a49a38b1'  # User Administrator
        '29232cdf-9323-42fd-ade2-1d097af3e4de'  # Exchange Administrator
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'  # SharePoint Administrator
        '966707d0-3269-4727-9be2-8c3a10f19b9d'  # Password Administrator
        'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'  # Conditional Access Administrator
        'c4e39bd9-1100-46d3-8c65-fb160da0071f'  # Authentication Administrator
        '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2'  # Hybrid Identity Administrator
    )

    # Privileged Azure role names
    $privilegedAzureRoles = @(
        'Owner'
        'Contributor'
        'User Access Administrator'
        'Virtual Machine Contributor'
        'Key Vault Administrator'
        'Key Vault Secrets Officer'
        'Key Vault Secrets User'
        'Storage Account Contributor'
        'Storage Blob Data Owner'
        'Storage Blob Data Contributor'
        'Automation Contributor'
        'Managed Identity Contributor'
        'Managed Identity Operator'
        'Azure Kubernetes Service Cluster Admin Role'
        'Azure Kubernetes Service RBAC Admin'
    )

    # Initialize buffer and stats
    $resourcesJsonL = New-Object System.Text.StringBuilder(2097152)
    $stats = @{
        DirectoryRoles = 0
        DirectoryBuiltIn = 0
        DirectoryCustom = 0
        DirectoryPrivileged = 0
        AzureRoles = 0
        AzureBuiltIn = 0
        AzureCustom = 0
        AzurePrivileged = 0
    }

    # Initialize blob
    $resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $resourcesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        return @{ Success = $false; Error = "Blob initialization failed: $($_.Exception.Message)" }
    }

    #region 1. Collect Directory Role Definitions (Entra ID)
    Write-Verbose "Collecting Directory Role Definitions..."
    $roleDefsUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"

    while ($roleDefsUri) {
        try {
            $response = Invoke-GraphWithRetry -Uri $roleDefsUri -AccessToken $graphToken

            foreach ($roleDef in $response.value) {
                $roleTemplateId = $roleDef.templateId ?? $roleDef.id
                $isBuiltIn = $roleDef.isBuiltIn ?? $true
                $isPrivileged = $privilegedDirectoryRoles -contains $roleTemplateId

                if ($isBuiltIn) { $stats.DirectoryBuiltIn++ } else { $stats.DirectoryCustom++ }
                if ($isPrivileged) { $stats.DirectoryPrivileged++ }

                $roleResource = @{
                    id = $roleDef.id
                    objectId = $roleDef.id
                    resourceType = "directoryRoleDefinition"
                    displayName = $roleDef.displayName ?? ""
                    description = $roleDef.description ?? ""
                    roleTemplateId = $roleTemplateId
                    isBuiltIn = $isBuiltIn
                    isEnabled = $roleDef.isEnabled ?? $true
                    isPrivileged = $isPrivileged
                    version = $roleDef.version ?? $null
                    resourceScopes = $roleDef.resourceScopes ?? @()
                    rolePermissions = $roleDef.rolePermissions ?? @()
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($roleResource | ConvertTo-Json -Compress -Depth 10))
                $stats.DirectoryRoles++
            }

            $roleDefsUri = $response.'@odata.nextLink'
        }
        catch {
            Write-Warning "Failed to retrieve directory role definitions: $_"
            break
        }
    }
    Write-Verbose "  Directory roles: $($stats.DirectoryRoles)"
    #endregion

    #region 2. Collect Azure Role Definitions (ARM)
    Write-Verbose "Collecting Azure Role Definitions..."
    $processedRoleIds = [System.Collections.Generic.HashSet[string]]::new()
    $headers = @{ 'Authorization' = "Bearer $armToken"; 'Content-Type' = 'application/json' }

    # Get subscriptions
    $subsUri = "https://management.azure.com/subscriptions?api-version=2022-12-01"
    $subsResponse = Invoke-RestMethod -Uri $subsUri -Method GET -Headers $headers -ErrorAction Stop

    foreach ($sub in $subsResponse.value) {
        try {
            $roleDefsUri = "https://management.azure.com/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
            $response = Invoke-RestMethod -Uri $roleDefsUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($roleDef in $response.value) {
                $roleId = $roleDef.name
                if ($processedRoleIds.Contains($roleId)) { continue }
                [void]$processedRoleIds.Add($roleId)

                $roleName = $roleDef.properties.roleName ?? ""
                $roleType = $roleDef.properties.type ?? "BuiltInRole"
                $isBuiltIn = $roleType -eq "BuiltInRole"
                $isPrivileged = $privilegedAzureRoles -contains $roleName

                if ($isBuiltIn) { $stats.AzureBuiltIn++ } else { $stats.AzureCustom++ }
                if ($isPrivileged) { $stats.AzurePrivileged++ }

                $roleResource = @{
                    id = $roleDef.id
                    objectId = $roleId
                    resourceType = "azureRoleDefinition"
                    displayName = $roleName
                    description = $roleDef.properties.description ?? ""
                    roleName = $roleName
                    roleType = $roleType
                    isBuiltIn = $isBuiltIn
                    isPrivileged = $isPrivileged
                    permissions = $roleDef.properties.permissions ?? @()
                    assignableScopes = $roleDef.properties.assignableScopes ?? @()
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($roleResource | ConvertTo-Json -Compress -Depth 10))
                $stats.AzureRoles++
            }
        }
        catch {
            Write-Warning "Failed to collect role definitions from subscription $($sub.subscriptionId): $_"
        }
    }
    Write-Verbose "  Azure roles: $($stats.AzureRoles)"
    #endregion

    # Flush to blob
    if ($resourcesJsonL.Length -gt 0) {
        Add-BlobContent -StorageAccountName $storageAccountName `
                        -ContainerName $containerName `
                        -BlobName $resourcesBlobName `
                        -Content $resourcesJsonL.ToString() `
                        -AccessToken $storageToken `
                        -MaxRetries 3 `
                        -BaseRetryDelaySeconds 2
    }

    # Cleanup
    $resourcesJsonL = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    $totalRoles = $stats.DirectoryRoles + $stats.AzureRoles
    Write-Verbose "Role Definitions collection complete: $totalRoles total (Directory: $($stats.DirectoryRoles), Azure: $($stats.AzureRoles))"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        RoleDefinitionCount = $totalRoles
        DirectoryRoleCount = $stats.DirectoryRoles
        AzureRoleCount = $stats.AzureRoles
        Statistics = $stats
        Summary = @{
            timestamp = $timestampFormatted
            totalRoleDefinitions = $totalRoles
            directoryRoles = $stats.DirectoryRoles
            directoryBuiltIn = $stats.DirectoryBuiltIn
            directoryCustom = $stats.DirectoryCustom
            directoryPrivileged = $stats.DirectoryPrivileged
            azureRoles = $stats.AzureRoles
            azureBuiltIn = $stats.AzureBuiltIn
            azureCustom = $stats.AzureCustom
            azurePrivileged = $stats.AzurePrivileged
        }
    }
}
catch {
    Write-Error "CollectRoleDefinitions failed: $_"
    return @{ Success = $false; Error = $_.Exception.Message }
}
#endregion
