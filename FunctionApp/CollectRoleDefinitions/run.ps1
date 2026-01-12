<#
.SYNOPSIS
    Collects Role Definitions from both Entra ID and Azure Resource Manager
.DESCRIPTION
    Consolidated Role Definitions Collector:
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

    # Dangerous action patterns for dynamic privileged role detection
    # These patterns indicate a role can perform security-sensitive operations
    $dangerousDirectoryActionPatterns = @(
        'microsoft.directory/*/allTasks'                          # Full tenant admin
        'microsoft.directory/applications/credentials/*'           # App secret manipulation
        'microsoft.directory/servicePrincipals/credentials/*'      # SP secret manipulation
        'microsoft.directory/users/password/*'                     # Password resets
        'microsoft.directory/users/authenticationMethods/*'        # MFA bypass
        'microsoft.directory/roleAssignments/*'                    # Role assignment
        'microsoft.directory/roleDefinitions/*'                    # Role definition changes
        'microsoft.directory/conditionalAccessPolicies/*'          # CA policy changes
        'microsoft.directory/groups/members/*'                     # Group membership (could be role-assignable)
        'microsoft.directory/deviceManagementPolicies/*'           # Device policies
        'microsoft.directory/authorizationPolicy/*'                # Tenant authorization
        'microsoft.directory/entitlementManagement/*'              # Access packages
        'microsoft.directory/permissionGrantPolicies/*'            # Consent policies
    )

    # Function to check if a directory role is privileged based on its permissions
    function Test-DirectoryRolePrivileged {
        param([array]$RolePermissions)
        foreach ($perm in $RolePermissions) {
            foreach ($action in ($perm.allowedResourceActions ?? @())) {
                foreach ($pattern in $dangerousDirectoryActionPatterns) {
                    # Convert pattern to regex (replace * with .*)
                    $regex = '^' + ($pattern -replace '\*', '.*') + '$'
                    if ($action -match $regex) { return $true }
                }
            }
        }
        return $false
    }

    # Dangerous action patterns for Azure RBAC roles
    $dangerousAzureActionPatterns = @(
        '*'                                                        # Full control (Owner)
        '*/write'                                                  # Write access to everything
        'Microsoft.Authorization/*'                                # RBAC manipulation
        'Microsoft.Authorization/roleAssignments/*'                # Role assignment
        'Microsoft.KeyVault/vaults/secrets/*'                      # Key Vault secrets
        'Microsoft.KeyVault/vaults/keys/*'                         # Key Vault keys
        'Microsoft.Compute/virtualMachines/*'                      # VM control
        'Microsoft.Compute/virtualMachineScaleSets/*'              # VMSS control
        'Microsoft.ContainerService/managedClusters/*'             # AKS control
        'Microsoft.Storage/storageAccounts/blobServices/containers/*' # Blob access
        'Microsoft.Web/sites/config/*'                             # App Service config (secrets)
        'Microsoft.Automation/automationAccounts/runbooks/*'       # Automation runbooks
        'Microsoft.ManagedIdentity/userAssignedIdentities/*'       # Managed identity control
    )

    # Function to check if an Azure role is privileged based on its permissions
    function Test-AzureRolePrivileged {
        param([array]$Permissions)
        foreach ($perm in $Permissions) {
            $allActions = @()
            $allActions += ($perm.actions ?? @())
            $allActions += ($perm.dataActions ?? @())
            foreach ($action in $allActions) {
                foreach ($pattern in $dangerousAzureActionPatterns) {
                    $regex = '^' + ($pattern -replace '\*', '.*') + '$'
                    if ($action -match $regex) { return $true }
                }
            }
        }
        return $false
    }

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
                # Dynamic privileged detection based on role permissions
                $isPrivileged = Test-DirectoryRolePrivileged -RolePermissions ($roleDef.rolePermissions ?? @())

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
                # Dynamic privileged detection based on role permissions
                $isPrivileged = Test-AzureRolePrivileged -Permissions ($roleDef.properties.permissions ?? @())

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
