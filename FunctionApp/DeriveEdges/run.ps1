<#
.SYNOPSIS
    Derives abuse capability edges from raw permission/role/ownership edges
.DESCRIPTION
    V3.5 Feature: Abuse Edge Derivation

    Reads raw edges from Cosmos DB and derives high-level abuse capabilities:
    - appRoleAssignment edges with dangerous Graph permissions → canAddSecretToAnyApp, etc.
    - directoryRole edges with privileged roles → isGlobalAdmin, canAssignAnyRole, etc.
    - appOwner/spOwner edges → canAddSecret (to specific app/SP)
    - groupOwner edges for role-assignable groups → canAssignRolesViaGroup

    Output: Derived edges written to edges container (edgeTypes: can*, is*, azure*)

    This is "the core BloodHound value" - converting raw permissions to attack paths.
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
    return @{ Success = $false; Error = $errorMsg }
}
#endregion

#region Load Dangerous Permissions Reference
try {
    $dangerousPermsPath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\DangerousPermissions.psd1"
    $DangerousPerms = Import-PowerShellDataFile -Path $dangerousPermsPath -ErrorAction Stop
    Write-Verbose "Loaded DangerousPermissions.psd1 with $($DangerousPerms.GraphPermissions.Count) Graph permissions, $($DangerousPerms.DirectoryRoles.Count) directory roles"
}
catch {
    $errorMsg = "Failed to load DangerousPermissions.psd1: $($_.Exception.Message)"
    Write-Error $errorMsg
    return @{ Success = $false; Error = $errorMsg }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting abuse edge derivation"

    # Get timestamp from orchestrator
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get Cosmos DB connection info
    $cosmosConnectionString = $env:CosmosDbConnectionString
    if (-not $cosmosConnectionString) {
        throw "CosmosDbConnectionString environment variable not set"
    }

    # Parse connection string
    $connParts = @{}
    $cosmosConnectionString.Split(';') | ForEach-Object {
        if ($_ -match '(.+?)=(.+)') {
            $connParts[$matches[1]] = $matches[2]
        }
    }
    $cosmosEndpoint = $connParts['AccountEndpoint']
    $cosmosKey = $connParts['AccountKey']
    $databaseName = "EntraData"
    $containerName = "edges"

    # Stats tracking
    $stats = @{
        GraphPermissionAbuse = 0
        DirectoryRoleAbuse = 0
        OwnershipAbuse = 0
        AzureRbacAbuse = 0
        TotalDerived = 0
        Errors = 0
    }

    # Collected abuse edges
    $abuseEdges = [System.Collections.Generic.List[object]]::new()

    #region Phase 1: Graph Permission Abuse (appRoleAssignment edges)
    Write-Verbose "=== Phase 1: Deriving Graph Permission Abuse Edges ==="

    # Query appRoleAssignment edges (filter to MS Graph done post-query via resourceId match)
    $query = "SELECT * FROM c WHERE c.edgeType = 'appRoleAssignment' AND c.deleted != true"

    try {
        $appRoleEdges = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                              -Key $cosmosKey `
                                              -DatabaseName $databaseName `
                                              -ContainerName $containerName `
                                              -Query $query `
                                              -PartitionKey "appRoleAssignment"

        Write-Verbose "Found $($appRoleEdges.Count) appRoleAssignment edges to analyze"

        foreach ($edge in $appRoleEdges) {
            $appRoleId = $edge.appRoleId
            if (-not $appRoleId) { continue }

            # Check if this is a dangerous Graph permission
            if ($DangerousPerms.GraphPermissions.ContainsKey($appRoleId)) {
                $permInfo = $DangerousPerms.GraphPermissions[$appRoleId]

                # Create derived abuse edge
                $abuseEdge = @{
                    id = [guid]::NewGuid().ToString()
                    objectId = "$($edge.sourceId)_$($permInfo.TargetType)_$($permInfo.AbuseEdge)"
                    edgeType = $permInfo.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType
                    sourceDisplayName = $edge.sourceDisplayName
                    targetId = $permInfo.TargetType  # e.g., "allApps", "allGroups"
                    targetType = "virtual"
                    targetDisplayName = $permInfo.TargetType
                    deleted = $false
                    derivedFrom = "appRoleAssignment"
                    derivedFromEdgeId = $edge.objectId
                    permissionName = $permInfo.Name
                    severity = $permInfo.Severity
                    description = $permInfo.Description
                    collectionTimestamp = $timestampFormatted
                    lastModified = $timestampFormatted
                }

                # Copy source denormalization fields
                if ($edge.sourceUserPrincipalName) { $abuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
                if ($edge.sourceAccountEnabled) { $abuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }
                if ($edge.sourceAppId) { $abuseEdge.sourceAppId = $edge.sourceAppId }
                if ($edge.sourceServicePrincipalType) { $abuseEdge.sourceServicePrincipalType = $edge.sourceServicePrincipalType }

                $abuseEdges.Add($abuseEdge)
                $stats.GraphPermissionAbuse++
            }
        }
    }
    catch {
        Write-Warning "Error querying appRoleAssignment edges: $_"
        $stats.Errors++
    }
    #endregion

    #region Phase 2: Directory Role Abuse
    Write-Verbose "=== Phase 2: Deriving Directory Role Abuse Edges ==="

    $query = "SELECT * FROM c WHERE c.edgeType = 'directoryRole' AND c.deleted != true"

    try {
        $roleEdges = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                           -Key $cosmosKey `
                                           -DatabaseName $databaseName `
                                           -ContainerName $containerName `
                                           -Query $query `
                                           -PartitionKey "directoryRole"

        Write-Verbose "Found $($roleEdges.Count) directoryRole edges to analyze"

        foreach ($edge in $roleEdges) {
            $roleTemplateId = $edge.targetRoleTemplateId
            if (-not $roleTemplateId) { continue }

            # Check if this is a dangerous role
            if ($DangerousPerms.DirectoryRoles.ContainsKey($roleTemplateId)) {
                $roleInfo = $DangerousPerms.DirectoryRoles[$roleTemplateId]

                # Create abuse edges for each capability
                foreach ($abuseType in $roleInfo.AbuseEdges) {
                    $abuseEdge = @{
                        id = [guid]::NewGuid().ToString()
                        objectId = "$($edge.sourceId)_tenant_$abuseType"
                        edgeType = $abuseType
                        sourceId = $edge.sourceId
                        sourceType = $edge.sourceType
                        sourceDisplayName = $edge.sourceDisplayName
                        targetId = "tenant"
                        targetType = "virtual"
                        targetDisplayName = "Tenant"
                        deleted = $false
                        derivedFrom = "directoryRole"
                        derivedFromEdgeId = $edge.objectId
                        roleName = $roleInfo.Name
                        roleTemplateId = $roleTemplateId
                        severity = $roleInfo.Severity
                        tier = $roleInfo.Tier
                        description = $roleInfo.Description
                        collectionTimestamp = $timestampFormatted
                        lastModified = $timestampFormatted
                    }

                    # Copy source denormalization fields
                    if ($edge.sourceUserPrincipalName) { $abuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
                    if ($edge.sourceAccountEnabled) { $abuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }
                    if ($edge.sourceAppId) { $abuseEdge.sourceAppId = $edge.sourceAppId }
                    if ($edge.sourceSecurityEnabled) { $abuseEdge.sourceSecurityEnabled = $edge.sourceSecurityEnabled }

                    $abuseEdges.Add($abuseEdge)
                    $stats.DirectoryRoleAbuse++
                }
            }
        }
    }
    catch {
        Write-Warning "Error querying directoryRole edges: $_"
        $stats.Errors++
    }
    #endregion

    #region Phase 3: Ownership Abuse (App/SP Owners → canAddSecret)
    Write-Verbose "=== Phase 3: Deriving Ownership Abuse Edges ==="

    # Query appOwner and spOwner edges
    foreach ($ownerType in @('appOwner', 'spOwner')) {
        $query = "SELECT * FROM c WHERE c.edgeType = '$ownerType' AND c.deleted != true"

        try {
            $ownerEdges = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                                -Key $cosmosKey `
                                                -DatabaseName $databaseName `
                                                -ContainerName $containerName `
                                                -Query $query `
                                                -PartitionKey $ownerType

            Write-Verbose "Found $($ownerEdges.Count) $ownerType edges"

            foreach ($edge in $ownerEdges) {
                $ownerAbuse = $DangerousPerms.OwnershipAbuse[$ownerType]

                $abuseEdge = @{
                    id = [guid]::NewGuid().ToString()
                    objectId = "$($edge.sourceId)_$($edge.targetId)_$($ownerAbuse.AbuseEdge)"
                    edgeType = $ownerAbuse.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType
                    sourceDisplayName = $edge.sourceDisplayName
                    targetId = $edge.targetId
                    targetType = $edge.targetType
                    targetDisplayName = $edge.targetDisplayName
                    deleted = $false
                    derivedFrom = $ownerType
                    derivedFromEdgeId = $edge.objectId
                    description = $ownerAbuse.Description
                    collectionTimestamp = $timestampFormatted
                    lastModified = $timestampFormatted
                }

                # Copy target fields for apps/SPs
                if ($edge.targetAppId) { $abuseEdge.targetAppId = $edge.targetAppId }
                if ($edge.targetSignInAudience) { $abuseEdge.targetSignInAudience = $edge.targetSignInAudience }
                if ($edge.targetServicePrincipalType) { $abuseEdge.targetServicePrincipalType = $edge.targetServicePrincipalType }

                # Copy source fields
                if ($edge.sourceUserPrincipalName) { $abuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
                if ($edge.sourceAccountEnabled) { $abuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }

                $abuseEdges.Add($abuseEdge)
                $stats.OwnershipAbuse++
            }
        }
        catch {
            Write-Warning "Error querying $ownerType edges: $_"
            $stats.Errors++
        }
    }

    # Group ownership - special handling for role-assignable groups
    $query = "SELECT * FROM c WHERE c.edgeType = 'groupOwner' AND c.deleted != true"

    try {
        $groupOwnerEdges = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                                 -Key $cosmosKey `
                                                 -DatabaseName $databaseName `
                                                 -ContainerName $containerName `
                                                 -Query $query `
                                                 -PartitionKey "groupOwner"

        Write-Verbose "Found $($groupOwnerEdges.Count) groupOwner edges"

        foreach ($edge in $groupOwnerEdges) {
            $groupOwnerAbuse = $DangerousPerms.OwnershipAbuse.groupOwner

            # Basic group modification capability
            $abuseEdge = @{
                id = [guid]::NewGuid().ToString()
                objectId = "$($edge.sourceId)_$($edge.targetId)_$($groupOwnerAbuse.AbuseEdge)"
                edgeType = $groupOwnerAbuse.AbuseEdge
                sourceId = $edge.sourceId
                sourceType = $edge.sourceType
                sourceDisplayName = $edge.sourceDisplayName
                targetId = $edge.targetId
                targetType = $edge.targetType
                targetDisplayName = $edge.targetDisplayName
                deleted = $false
                derivedFrom = "groupOwner"
                derivedFromEdgeId = $edge.objectId
                description = $groupOwnerAbuse.Description
                collectionTimestamp = $timestampFormatted
                lastModified = $timestampFormatted
            }

            if ($edge.sourceUserPrincipalName) { $abuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
            if ($edge.sourceAccountEnabled) { $abuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }

            $abuseEdges.Add($abuseEdge)
            $stats.OwnershipAbuse++

            # Additional edge if group is role-assignable
            if ($edge.targetIsAssignableToRole -eq $true) {
                $roleAssignableAbuse = $groupOwnerAbuse.ConditionalAbuse.IsRoleAssignable

                $roleAbuseEdge = @{
                    id = [guid]::NewGuid().ToString()
                    objectId = "$($edge.sourceId)_$($edge.targetId)_$($roleAssignableAbuse.AbuseEdge)"
                    edgeType = $roleAssignableAbuse.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType
                    sourceDisplayName = $edge.sourceDisplayName
                    targetId = $edge.targetId
                    targetType = $edge.targetType
                    targetDisplayName = $edge.targetDisplayName
                    deleted = $false
                    derivedFrom = "groupOwner"
                    derivedFromEdgeId = $edge.objectId
                    description = $roleAssignableAbuse.Description
                    isRoleAssignableGroup = $true
                    collectionTimestamp = $timestampFormatted
                    lastModified = $timestampFormatted
                }

                if ($edge.sourceUserPrincipalName) { $roleAbuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
                if ($edge.sourceAccountEnabled) { $roleAbuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }

                $abuseEdges.Add($roleAbuseEdge)
                $stats.OwnershipAbuse++
            }
        }
    }
    catch {
        Write-Warning "Error querying groupOwner edges: $_"
        $stats.Errors++
    }
    #endregion

    #region Phase 4: Azure RBAC Abuse (for cross-cloud attack paths)
    Write-Verbose "=== Phase 4: Deriving Azure RBAC Abuse Edges ==="

    $query = "SELECT * FROM c WHERE c.edgeType = 'azureRoleAssignment' AND c.deleted != true"

    try {
        $rbacEdges = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                           -Key $cosmosKey `
                                           -DatabaseName $databaseName `
                                           -ContainerName $containerName `
                                           -Query $query `
                                           -PartitionKey "azureRoleAssignment"

        Write-Verbose "Found $($rbacEdges.Count) azureRoleAssignment edges"

        foreach ($edge in $rbacEdges) {
            $roleDefId = $edge.targetRoleDefinitionId
            if (-not $roleDefId) { continue }

            # Extract the GUID from role definition ID path
            # Format: /subscriptions/.../providers/Microsoft.Authorization/roleDefinitions/{guid}
            if ($roleDefId -match '/roleDefinitions/([a-f0-9-]+)$') {
                $roleGuid = $matches[1]

                if ($DangerousPerms.AzureRbacAbuse.ContainsKey($roleGuid)) {
                    $rbacInfo = $DangerousPerms.AzureRbacAbuse[$roleGuid]

                    $abuseEdge = @{
                        id = [guid]::NewGuid().ToString()
                        objectId = "$($edge.sourceId)_$($edge.scope)_$($rbacInfo.AbuseEdge)"
                        edgeType = $rbacInfo.AbuseEdge
                        sourceId = $edge.sourceId
                        sourceType = $edge.sourceType
                        sourceDisplayName = $edge.sourceDisplayName
                        targetId = $edge.scope
                        targetType = "azureScope"
                        targetDisplayName = $edge.scopeDisplayName
                        scope = $edge.scope
                        scopeType = $edge.scopeType
                        deleted = $false
                        derivedFrom = "azureRoleAssignment"
                        derivedFromEdgeId = $edge.objectId
                        roleName = $rbacInfo.Name
                        severity = $rbacInfo.Severity
                        description = $rbacInfo.Description
                        collectionTimestamp = $timestampFormatted
                        lastModified = $timestampFormatted
                    }

                    if ($edge.sourceUserPrincipalName) { $abuseEdge.sourceUserPrincipalName = $edge.sourceUserPrincipalName }
                    if ($edge.sourceAccountEnabled) { $abuseEdge.sourceAccountEnabled = $edge.sourceAccountEnabled }
                    if ($edge.sourceAppId) { $abuseEdge.sourceAppId = $edge.sourceAppId }

                    $abuseEdges.Add($abuseEdge)
                    $stats.AzureRbacAbuse++
                }
            }
        }
    }
    catch {
        Write-Warning "Error querying azureRoleAssignment edges: $_"
        $stats.Errors++
    }
    #endregion

    $stats.TotalDerived = $abuseEdges.Count
    Write-Verbose "Derived $($stats.TotalDerived) abuse edges total"

    # Output to Cosmos DB via output binding
    if ($abuseEdges.Count -gt 0) {
        Push-OutputBinding -Name edgesOut -Value $abuseEdges
        Write-Verbose "Pushed $($abuseEdges.Count) abuse edges to Cosmos DB"
    }

    return @{
        Success = $true
        Statistics = $stats
        DerivedEdgeCount = $abuseEdges.Count
        Timestamp = $timestampFormatted
    }
}
catch {
    $errorMsg = "DeriveEdges failed: $($_.Exception.Message)"
    Write-Error $errorMsg
    Write-Error $_.ScriptStackTrace
    return @{
        Success = $false
        Error = $errorMsg
        Statistics = $stats
    }
}
#endregion

#region Helper Function - Invoke-CosmosDbQuery
function Invoke-CosmosDbQuery {
    param(
        [string]$Endpoint,
        [string]$Key,
        [string]$DatabaseName,
        [string]$ContainerName,
        [string]$Query,
        [string]$PartitionKey
    )

    $resourceLink = "dbs/$DatabaseName/colls/$ContainerName"
    $uri = "$Endpoint$resourceLink/docs"

    $dateString = [DateTime]::UtcNow.ToString("r")

    # Generate auth signature
    $keyBytes = [Convert]::FromBase64String($Key)
    $stringToSign = "post`n$($resourceLink.ToLower())/docs`n$dateString`n"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign.ToLower()))
    $signature = [Convert]::ToBase64String($hashBytes)
    $authHeader = [Uri]::EscapeDataString("type=master&ver=1.0&sig=$signature")

    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date" = $dateString
        "x-ms-version" = "2018-12-31"
        "Content-Type" = "application/query+json"
        "x-ms-documentdb-isquery" = "true"
        "x-ms-documentdb-query-enablecrosspartition" = "true"
    }

    if ($PartitionKey) {
        $headers["x-ms-documentdb-partitionkey"] = "[`"$PartitionKey`"]"
    }

    $body = @{
        query = $Query
    } | ConvertTo-Json

    $results = @()
    $continuationToken = $null

    do {
        if ($continuationToken) {
            $headers["x-ms-continuation"] = $continuationToken
        }

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
            $results += $response.Documents
            $continuationToken = $response.Headers["x-ms-continuation"]
        }
        catch {
            Write-Warning "Cosmos DB query failed: $_"
            break
        }
    } while ($continuationToken)

    return $results
}
#endregion
