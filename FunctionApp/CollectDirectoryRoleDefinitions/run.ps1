<#
.SYNOPSIS
    Collects Directory Role Definitions from Microsoft Entra ID
.DESCRIPTION
    V3.1 Architecture: Synthetic vertices for role definitions
    - Queries Graph API /roleManagement/directory/roleDefinitions
    - Outputs to resources.jsonl with resourceType="directoryRoleDefinition"
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
    Write-Verbose "Starting Directory Role Definitions collection"

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
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
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

    # Privileged role template IDs (high-impact roles)
    $privilegedRoleTemplates = @(
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
        '729827e3-9c14-49f7-bb1b-9608f156bbb8'  # Helpdesk Administrator
        'c4e39bd9-1100-46d3-8c65-fb160da0071f'  # Authentication Administrator
        '44367163-eba1-44c3-98af-f5787879f96a'  # Dynamics 365 Administrator
        '11648597-926c-4cf3-9c36-bcebb0ba8dcc'  # Power Platform Administrator
        'e3973bdf-4987-49ae-837a-ba8e231c7286'  # Azure DevOps Administrator
        '69091246-20e8-4a56-aa4d-066075b2a7a8'  # Teams Administrator
        '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2'  # Hybrid Identity Administrator
        '7495fdc4-34c4-4d15-a289-98788ce399fd'  # Azure AD Joined Device Local Administrator
        '9f06204d-73c1-4d4c-880a-6edb90606fd8'  # Azure Information Protection Administrator
    )

    # Initialize counters and buffers
    $resourcesJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $roleCount = 0
    $builtInCount = 0
    $customCount = 0
    $privilegedCount = 0

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

    # Collect directory role definitions
    $roleDefsUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"

    while ($roleDefsUri) {
        try {
            $response = Invoke-GraphWithRetry -Uri $roleDefsUri -AccessToken $graphToken

            foreach ($roleDef in $response.value) {
                $roleTemplateId = $roleDef.templateId ?? $roleDef.id
                $isBuiltIn = $roleDef.isBuiltIn ?? $true
                $isPrivileged = $privilegedRoleTemplates -contains $roleTemplateId

                if ($isBuiltIn) { $builtInCount++ } else { $customCount++ }
                if ($isPrivileged) { $privilegedCount++ }

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
                    inheritsPermissionsFrom = $roleDef.inheritsPermissionsFrom ?? @()
                    effectiveFrom = $timestampFormatted
                    effectiveTo = $null
                    collectionTimestamp = $timestampFormatted
                }

                [void]$resourcesJsonL.AppendLine(($roleResource | ConvertTo-Json -Compress -Depth 10))
                $roleCount++
            }

            $roleDefsUri = $response.'@odata.nextLink'
        }
        catch {
            Write-Warning "Failed to retrieve role definitions: $_"
            break
        }
    }

    # Write to blob
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

    Write-Verbose "Directory role definitions collection complete: $roleCount total"

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
    Write-Error "Directory role definitions collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
