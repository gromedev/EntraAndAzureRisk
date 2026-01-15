<#
.SYNOPSIS
    Derives abuse capability edges from raw permission/role/ownership edges
.DESCRIPTION
    Abuse Edge Derivation

    Reads raw edges from Cosmos DB (via input binding) and derives high-level abuse capabilities:
    - appRoleAssignment edges with dangerous Graph permissions → canAddSecretToAnyApp, etc.
    - directoryRole edges with privileged roles → isGlobalAdmin, canAssignAnyRole, etc.
    - appOwner/spOwner edges → canAddSecret (to specific app/SP)
    - groupOwner edges for role-assignable groups → canAssignRolesViaGroup

    Output: Derived edges written to edges container (edgeTypes: can*, is*, azure*)

    This is "the core BloodHound value" - converting raw permissions to attack paths.
#>

param($ActivityInput, $edgesIn)

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

    # Log input binding data
    Write-Information "[DERIVE-DEBUG] edgesIn received: $($edgesIn.Count) edges from input binding" -InformationAction Continue

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

    # Filter appRoleAssignment edges from input binding
    $appRoleEdges = @($edgesIn | Where-Object { $_.edgeType -eq 'appRoleAssignment' })

    Write-Information "[DERIVE-DEBUG] Found $($appRoleEdges.Count) appRoleAssignment edges to analyze" -InformationAction Continue

    # DEBUG: Log sample edge structure and first few appRoleIds
    if ($appRoleEdges.Count -gt 0) {
        Write-Information "[DERIVE-DEBUG] Sample edge keys: $($appRoleEdges[0].PSObject.Properties.Name -join ', ')" -InformationAction Continue
        $sampleAppRoleIds = ($appRoleEdges | Select-Object -First 5).appRoleId | Where-Object { $_ }
        Write-Information "[DERIVE-DEBUG] First 5 appRoleIds: $($sampleAppRoleIds -join ', ')" -InformationAction Continue
        Write-Information "[DERIVE-DEBUG] DangerousPerms keys count: $($DangerousPerms.GraphPermissions.Keys.Count)" -InformationAction Continue
        Write-Information "[DERIVE-DEBUG] Looking for: $($DangerousPerms.GraphPermissions.Keys | Select-Object -First 3 | ForEach-Object { $_ })" -InformationAction Continue
    } else {
        Write-Information "[DERIVE-DEBUG] No appRoleAssignment edges found in input!" -InformationAction Continue
    }

    try {
        $matchCount = 0
        foreach ($edge in $appRoleEdges) {
            $appRoleId = $edge.appRoleId
            if (-not $appRoleId) { continue }

            # Check if this is a dangerous Graph permission
            $isMatch = $DangerousPerms.GraphPermissions.ContainsKey($appRoleId)
            if ($matchCount -lt 5) {
                Write-Information "[DERIVE-DEBUG] Checking appRoleId '$appRoleId' - Match: $isMatch" -InformationAction Continue
            }
            if ($isMatch) {
                $matchCount++
                $permInfo = $DangerousPerms.GraphPermissions[$appRoleId]

                # Create derived abuse edge
                # Use objectId as id so Cosmos upserts instead of creating duplicates
                $derivedObjectId = "$($edge.sourceId)_$($permInfo.TargetType)_$($permInfo.AbuseEdge)"
                $abuseEdge = @{
                    id = $derivedObjectId
                    objectId = $derivedObjectId
                    edgeType = $permInfo.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType ?? ""
                    sourceDisplayName = $edge.sourceDisplayName ?? ""
                    targetId = $permInfo.TargetType  # e.g., "allApps", "allGroups"
                    targetType = "virtual"
                    targetDisplayName = $permInfo.TargetType ?? ""
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

    # Filter directoryRole edges from input binding
    $roleEdges = @($edgesIn | Where-Object { $_.edgeType -eq 'directoryRole' })

    Write-Information "[DERIVE-DEBUG] Found $($roleEdges.Count) directoryRole edges to analyze" -InformationAction Continue

    # DEBUG: Log sample role edge structure
    if ($roleEdges.Count -gt 0) {
        $sampleRoleTemplateIds = ($roleEdges | Select-Object -First 5).targetRoleTemplateId | Where-Object { $_ }
        Write-Information "[DERIVE-DEBUG] First 5 targetRoleTemplateIds: $($sampleRoleTemplateIds -join ', ')" -InformationAction Continue
    }

    try {
        foreach ($edge in $roleEdges) {
            $roleTemplateId = $edge.targetRoleTemplateId
            if (-not $roleTemplateId) { continue }

            # Check if this is a dangerous role
            if ($DangerousPerms.DirectoryRoles.ContainsKey($roleTemplateId)) {
                $roleInfo = $DangerousPerms.DirectoryRoles[$roleTemplateId]

                # Create abuse edges for each capability
                foreach ($abuseType in $roleInfo.AbuseEdges) {
                    # Use objectId as id so Cosmos upserts instead of creating duplicates
                    $derivedObjectId = "$($edge.sourceId)_tenant_$abuseType"
                    $abuseEdge = @{
                        id = $derivedObjectId
                        objectId = $derivedObjectId
                        edgeType = $abuseType
                        sourceId = $edge.sourceId
                        sourceType = $edge.sourceType ?? ""
                        sourceDisplayName = $edge.sourceDisplayName ?? ""
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

    # Filter appOwner and spOwner edges from input binding
    foreach ($ownerType in @('appOwner', 'spOwner')) {
        $ownerEdges = @($edgesIn | Where-Object { $_.edgeType -eq $ownerType })

        Write-Information "[DERIVE-DEBUG] Found $($ownerEdges.Count) $ownerType edges" -InformationAction Continue

        try {

            foreach ($edge in $ownerEdges) {
                $ownerAbuse = $DangerousPerms.OwnershipAbuse[$ownerType]

                # Use objectId as id so Cosmos upserts instead of creating duplicates
                $derivedObjectId = "$($edge.sourceId)_$($edge.targetId)_$($ownerAbuse.AbuseEdge)"
                $abuseEdge = @{
                    id = $derivedObjectId
                    objectId = $derivedObjectId
                    edgeType = $ownerAbuse.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType ?? ""
                    sourceDisplayName = $edge.sourceDisplayName ?? ""
                    targetId = $edge.targetId
                    targetType = $edge.targetType ?? ""
                    targetDisplayName = $edge.targetDisplayName ?? ""
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
    $groupOwnerEdges = @($edgesIn | Where-Object { $_.edgeType -eq 'groupOwner' })

    Write-Information "[DERIVE-DEBUG] Found $($groupOwnerEdges.Count) groupOwner edges" -InformationAction Continue

    try {

        foreach ($edge in $groupOwnerEdges) {
            $groupOwnerAbuse = $DangerousPerms.OwnershipAbuse.groupOwner

            # Basic group modification capability
            # Use objectId as id so Cosmos upserts instead of creating duplicates
            $derivedObjectId = "$($edge.sourceId)_$($edge.targetId)_$($groupOwnerAbuse.AbuseEdge)"
            $abuseEdge = @{
                id = $derivedObjectId
                objectId = $derivedObjectId
                edgeType = $groupOwnerAbuse.AbuseEdge
                sourceId = $edge.sourceId
                sourceType = $edge.sourceType ?? ""
                sourceDisplayName = $edge.sourceDisplayName ?? ""
                targetId = $edge.targetId
                targetType = $edge.targetType ?? ""
                targetDisplayName = $edge.targetDisplayName ?? ""
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

                # Use objectId as id so Cosmos upserts instead of creating duplicates
                $derivedRoleObjectId = "$($edge.sourceId)_$($edge.targetId)_$($roleAssignableAbuse.AbuseEdge)"
                $roleAbuseEdge = @{
                    id = $derivedRoleObjectId
                    objectId = $derivedRoleObjectId
                    edgeType = $roleAssignableAbuse.AbuseEdge
                    sourceId = $edge.sourceId
                    sourceType = $edge.sourceType ?? ""
                    sourceDisplayName = $edge.sourceDisplayName ?? ""
                    targetId = $edge.targetId
                    targetType = $edge.targetType ?? ""
                    targetDisplayName = $edge.targetDisplayName ?? ""
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

    # Filter azureRbac edges from input binding
    $rbacEdges = @($edgesIn | Where-Object { $_.edgeType -eq 'azureRbac' })

    Write-Information "[DERIVE-DEBUG] Found $($rbacEdges.Count) azureRbac edges" -InformationAction Continue

    try {

        foreach ($edge in $rbacEdges) {
            $roleDefId = $edge.targetRoleDefinitionId
            if (-not $roleDefId) { continue }

            # Extract the GUID from role definition ID path
            # Format: /subscriptions/.../providers/Microsoft.Authorization/roleDefinitions/{guid}
            if ($roleDefId -match '/roleDefinitions/([a-f0-9-]+)$') {
                $roleGuid = $matches[1]

                if ($DangerousPerms.AzureRbacAbuse.ContainsKey($roleGuid)) {
                    $rbacInfo = $DangerousPerms.AzureRbacAbuse[$roleGuid]

                    # Use objectId as id so Cosmos upserts instead of creating duplicates
                    $derivedObjectId = "$($edge.sourceId)_$($edge.scope)_$($rbacInfo.AbuseEdge)"
                    $abuseEdge = @{
                        id = $derivedObjectId
                        objectId = $derivedObjectId
                        edgeType = $rbacInfo.AbuseEdge
                        sourceId = $edge.sourceId
                        sourceType = $edge.sourceType ?? ""
                        sourceDisplayName = $edge.sourceDisplayName ?? ""
                        targetId = $edge.scope
                        targetType = "azureScope"
                        targetDisplayName = $edge.scopeDisplayName ?? ""
                        scope = $edge.scope ?? ""
                        scopeType = $edge.scopeType ?? ""
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
        Write-Warning "Error processing azureRbac edges: $_"
        $stats.Errors++
    }
    #endregion

    $stats.TotalDerived = $abuseEdges.Count

    # Log summary
    Write-Information "[DERIVE-DEBUG] === SUMMARY ===" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] Total edges in input: $($edgesIn.Count)" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] GraphPermissionAbuse: $($stats.GraphPermissionAbuse)" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] DirectoryRoleAbuse: $($stats.DirectoryRoleAbuse)" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] OwnershipAbuse: $($stats.OwnershipAbuse)" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] AzureRbacAbuse: $($stats.AzureRbacAbuse)" -InformationAction Continue
    Write-Information "[DERIVE-DEBUG] TotalDerived: $($stats.TotalDerived)" -InformationAction Continue

    # Output to Cosmos DB via output binding
    if ($abuseEdges.Count -gt 0) {
        Push-OutputBinding -Name edgesOut -Value $abuseEdges
        Write-Information "[DERIVE-DEBUG] Pushed $($abuseEdges.Count) abuse edges to Cosmos DB" -InformationAction Continue
    } else {
        Write-Information "[DERIVE-DEBUG] No abuse edges to push" -InformationAction Continue
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
