<#
.SYNOPSIS
    Collects Azure Role Definitions from Azure Resource Manager
.DESCRIPTION
    V3.1 Architecture: Synthetic vertices for Azure role definitions
    - Queries ARM API /providers/Microsoft.Authorization/roleDefinitions
    - Outputs to resources.jsonl with resourceType="azureRoleDefinition"
    - Includes isPrivileged flag for privileged roles
    - Returns summary statistics for orchestrator
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
    Write-Verbose "Starting Azure Role Definitions collection"

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

    # Get access tokens (cached)
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $azureToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{
            Success = $false
            Error = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Privileged Azure role names
    $privilegedAzureRoles = @(
        'Owner'
        'Contributor'
        'User Access Administrator'
        'Virtual Machine Contributor'
        'Key Vault Administrator'
        'Key Vault Secrets Officer'
        'Key Vault Secrets User'
        'Key Vault Certificates Officer'
        'Key Vault Crypto Officer'
        'Storage Account Contributor'
        'Storage Blob Data Owner'
        'Storage Blob Data Contributor'
        'Automation Contributor'
        'Logic App Contributor'
        'Website Contributor'
        'Managed Identity Contributor'
        'Managed Identity Operator'
        'Azure Kubernetes Service Cluster Admin Role'
        'Azure Kubernetes Service RBAC Admin'
        'Azure Kubernetes Service RBAC Cluster Admin'
    )

    # Initialize counters and buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(2097152)  # 2MB initial capacity
    $roleCount = 0
    $builtInCount = 0
    $customCount = 0
    $privilegedCount = 0
    $processedRoleIds = [System.Collections.Generic.HashSet[string]]::new()

    # Initialize append blob (V3: unified resources.jsonl)
    $resourcesBlobName = "$timestamp/$timestamp-resources.jsonl"
    Write-Verbose "Initializing append blob: $resourcesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $resourcesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Get subscriptions first
    $subscriptions = Get-AzureManagementPagedResult `
        -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" `
        -AccessToken $azureToken

    Write-Verbose "Found $($subscriptions.Count) subscriptions for role definition collection"

    foreach ($sub in $subscriptions) {
        try {
            # Get role definitions at subscription scope (includes built-in and custom)
            $roleDefsUri = "https://management.azure.com/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
            $headers = @{
                'Authorization' = "Bearer $azureToken"
                'Content-Type' = 'application/json'
            }

            $response = Invoke-RestMethod -Uri $roleDefsUri -Method GET -Headers $headers -ErrorAction Stop

            foreach ($roleDef in $response.value) {
                # Deduplicate (built-in roles appear in every subscription)
                $roleId = $roleDef.name  # GUID
                if ($processedRoleIds.Contains($roleId)) {
                    continue
                }
                [void]$processedRoleIds.Add($roleId)

                $roleName = $roleDef.properties.roleName ?? ""
                $roleType = $roleDef.properties.type ?? "BuiltInRole"
                $isBuiltIn = $roleType -eq "BuiltInRole"
                $isPrivileged = $privilegedAzureRoles -contains $roleName

                if ($isBuiltIn) { $builtInCount++ } else { $customCount++ }
                if ($isPrivileged) { $privilegedCount++ }

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
                $roleCount++
            }

            # Check for nextLink (though Azure rarely paginates role definitions)
            while ($response.nextLink) {
                $response = Invoke-RestMethod -Uri $response.nextLink -Method GET -Headers $headers -ErrorAction Stop

                foreach ($roleDef in $response.value) {
                    $roleId = $roleDef.name
                    if ($processedRoleIds.Contains($roleId)) {
                        continue
                    }
                    [void]$processedRoleIds.Add($roleId)

                    $roleName = $roleDef.properties.roleName ?? ""
                    $roleType = $roleDef.properties.type ?? "BuiltInRole"
                    $isBuiltIn = $roleType -eq "BuiltInRole"
                    $isPrivileged = $privilegedAzureRoles -contains $roleName

                    if ($isBuiltIn) { $builtInCount++ } else { $customCount++ }
                    if ($isPrivileged) { $privilegedCount++ }

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
                    $roleCount++
                }
            }
        }
        catch {
            Write-Warning "Failed to collect role definitions from subscription $($sub.subscriptionId): $_"
        }

        # Periodic flush
        if ($resourcesJsonL.Length -ge 1500000) {  # ~1.5MB
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $resourcesBlobName `
                            -Content $resourcesJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            $resourcesJsonL.Clear()
            Write-Verbose "Flushed Azure role definitions buffer ($roleCount total)"
        }
    }

    # Final flush
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

    Write-Verbose "Azure role definitions collection complete: $roleCount total"

    return @{
        Success = $true
        Timestamp = $timestamp
        ResourcesBlobName = $resourcesBlobName
        RoleDefinitionCount = $roleCount
        Summary = @{
            timestamp = $timestampFormatted
            totalRoleDefinitions = $roleCount
            builtInRoles = $builtInCount
            customRoles = $customCount
            privilegedRoles = $privilegedCount
        }
    }
}
catch {
    Write-Error "Azure role definitions collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
