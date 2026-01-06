<#
.SYNOPSIS
    Collects Directory Role data with members from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API /directoryRoles to get activated roles
    - For each role, queries /directoryRoles/{id}/members to get role members
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Token caching (eliminates redundant IMDS calls)
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
    'COSMOS_DB_ENDPOINT' = 'Cosmos DB endpoint for indexing'
    'COSMOS_DB_DATABASE' = 'Cosmos DB database name'
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
    Write-Verbose "Starting Directory Roles data collection"

    # Generate ISO 8601 timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
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

    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    # Initialize counters and buffers
    $rolesJsonL = New-Object System.Text.StringBuilder(524288)  # 512KB initial capacity
    $roleCount = 0
    $totalMembersCount = 0
    $writeThreshold = 500

    # Summary statistics
    $rolesWithMembersCount = 0
    $privilegedRolesCount = 0  # Global Admin, Privileged Role Admin, etc.

    # List of privileged role template IDs
    $privilegedRoleTemplates = @(
        '62e90394-69f5-4237-9190-012177145e10',  # Global Administrator
        'e8611ab8-c189-46e8-94e1-60213ab1f814',  # Privileged Role Administrator
        '194ae4cb-b126-40b2-bd5b-6091b380977d',  # Security Administrator
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3',  # Application Administrator
        '158c047a-c907-4556-b7ef-446551a6b5f7',  # Cloud Application Administrator
        '966707d0-3269-4727-9be2-8c3a10f19b9d',  # Password Administrator
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13',  # Privileged Authentication Administrator
        '29232cdf-9323-42fd-ade2-1d097af3e4de',  # Exchange Administrator
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c',  # SharePoint Administrator
        'fe930be7-5e62-47db-91af-98c3a49a38b1'   # User Administrator
    )

    # Initialize append blob
    $blobName = "$timestamp/$timestamp-directoryroles.jsonl"
    Write-Verbose "Initializing append blob: $blobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $blobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    # Query directory roles (only activated roles are returned)
    # Note: Requires RoleManagement.Read.Directory permission
    $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoles"

    Write-Verbose "Fetching directory roles..."

    try {
        $rolesResponse = Invoke-GraphWithRetry -Uri $rolesUri -AccessToken $graphToken
        $roles = $rolesResponse.value
        Write-Verbose "Found $($roles.Count) activated directory roles"
    }
    catch {
        Write-Error "Failed to retrieve directory roles: $_"
        return @{
            Success = $false
            Error = "Failed to retrieve directory roles: $($_.Exception.Message)"
        }
    }

    # Process each role and get members
    foreach ($role in $roles) {
        $roleCount++
        Write-Verbose "Processing role: $($role.displayName)"

        # Check if privileged role
        $isPrivileged = $privilegedRoleTemplates -contains $role.roleTemplateId

        # Get role members
        $membersUri = "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members"
        $members = @()

        try {
            # Handle pagination for members
            $nextMembersLink = $membersUri
            while ($nextMembersLink) {
                $membersResponse = Invoke-GraphWithRetry -Uri $nextMembersLink -AccessToken $graphToken
                if ($membersResponse.value) {
                    foreach ($member in $membersResponse.value) {
                        $members += @{
                            objectId = $member.id ?? ""
                            displayName = $member.displayName ?? ""
                            userPrincipalName = $member.userPrincipalName ?? ""
                            type = $member.'@odata.type' -replace '#microsoft.graph.', ''
                        }
                    }
                }
                $nextMembersLink = $membersResponse.'@odata.nextLink'
            }
        }
        catch {
            Write-Warning "Failed to get members for role $($role.displayName)`: $_"
        }

        if ($members.Count -gt 0) {
            $rolesWithMembersCount++
            $totalMembersCount += $members.Count
        }

        if ($isPrivileged) {
            $privilegedRolesCount++
        }

        # Create role object with members
        $roleObj = @{
            objectId = $role.id ?? ""
            displayName = $role.displayName ?? ""
            description = $role.description ?? ""
            roleTemplateId = $role.roleTemplateId ?? ""
            isPrivileged = $isPrivileged
            memberCount = $members.Count
            members = $members
            collectionTimestamp = $timestampFormatted
        }

        [void]$rolesJsonL.AppendLine(($roleObj | ConvertTo-Json -Compress -Depth 10))

        # Periodic flush to blob
        if ($rolesJsonL.Length -ge ($writeThreshold * 1000)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName $containerName `
                                -BlobName $blobName `
                                -Content $rolesJsonL.ToString() `
                                -AccessToken $storageToken `
                                -MaxRetries 3 `
                                -BaseRetryDelaySeconds 2

                Write-Verbose "Flushed $($rolesJsonL.Length) characters to blob"
                $rolesJsonL.Clear()
            }
            catch {
                Write-Error "CRITICAL: Blob write failed after retries $_"
                throw "Cannot continue - data loss would occur"
            }
        }
    }

    # Final flush
    if ($rolesJsonL.Length -gt 0) {
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                            -ContainerName $containerName `
                            -BlobName $blobName `
                            -Content $rolesJsonL.ToString() `
                            -AccessToken $storageToken `
                            -MaxRetries 3 `
                            -BaseRetryDelaySeconds 2
            Write-Verbose "Final flush: $($rolesJsonL.Length) characters written"
        }
        catch {
            Write-Error "CRITICAL: Final flush failed: $_"
            throw "Cannot complete collection"
        }
    }

    Write-Verbose "Directory roles collection complete: $roleCount roles written to $blobName"

    # Cleanup
    $rolesJsonL.Clear()
    $rolesJsonL = $null

    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'directoryRoles'
        totalCount = $roleCount
        rolesWithMembersCount = $rolesWithMembersCount
        privilegedRolesCount = $privilegedRolesCount
        totalMembersCount = $totalMembersCount
        blobPath = $blobName
    }

    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    Write-Verbose "Collection activity completed successfully!"

    return @{
        Success = $true
        RoleCount = $roleCount
        TotalMembersCount = $totalMembersCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-directoryroles.jsonl"
        Timestamp = $timestamp
        BlobName = $blobName
    }
}
catch {
    Write-Error "Unexpected error in CollectDirectoryRoles: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
