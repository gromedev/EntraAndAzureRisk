using namespace System.Net

# V3.5 Dashboard - 5 Unified Containers + Derived Edges
# 1. principals (users, groups, SPs, devices)
# 2. resources (applications + Azure resources + role definitions)
# 3. edges (all relationships + derived edges)
# 4. policies (CA, Intune compliance, App Protection, Named Locations)
# 5. audit (change tracking)

# Azure Functions runtime passes these parameters - not all are used in this function
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Request', Justification = 'Required by Azure Functions runtime')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TriggerMetadata', Justification = 'Required by Azure Functions runtime')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'eventsIn', Justification = 'Events container binding kept for future use')]
param(
    $Request,
    $TriggerMetadata,
    $principalsIn,
    $resourcesIn,
    $edgesIn,
    $policiesIn,
    $eventsIn,
    $auditIn
)

Add-Type -AssemblyName System.Web

function Format-Value {
    param($value, $maxLen = 200)
    if ($null -eq $value) { return '<span style="color:#999">null</span>' }
    if ($value -is [bool]) { if ($value) { return '<span style="color:#107c10">true</span>' } else { return '<span style="color:#d13438">false</span>' } }
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return '[]' }
        # For arrays, try to show content up to maxLen
        try {
            $json = $value | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue
            if ($json.Length -gt $maxLen) { $json = $json.Substring(0, $maxLen) + "..." }
            return '<span title="' + [System.Web.HttpUtility]::HtmlAttributeEncode($json) + '">[' + $value.Count + ' items]</span>'
        } catch {
            return "[$($value.Count) items]"
        }
    }
    if ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject] -or $value.GetType().Name -match 'Hashtable|OrderedDictionary') {
        # Convert to JSON for readable display
        try {
            $json = $value | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue
            $display = if ($json.Length -gt $maxLen) { $json.Substring(0, $maxLen) + "..." } else { $json }
            # Show abbreviated version with full content on hover
            return '<span title="' + [System.Web.HttpUtility]::HtmlAttributeEncode($json) + '">' + [System.Web.HttpUtility]::HtmlEncode($display) + '</span>'
        } catch {
            return '{object}'
        }
    }
    $str = $value.ToString()
    if ($str.Length -gt $maxLen) { $str = $str.Substring(0, $maxLen) + "..." }
    return [System.Web.HttpUtility]::HtmlEncode($str)
}

# Dynamically discover all columns from data, with priority columns first
# Priority columns are always shown (even if all null), other columns only shown if they have data
function Get-AllColumns {
    param($data, $priorityColumns = @())
    if ($null -eq $data -or $data.Count -eq 0) { return $priorityColumns }

    # Collect property names that have at least one non-null value
    $propsWithValues = @{}
    foreach ($item in $data) {
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in $item.Keys) {
                if ($null -ne $item[$key]) { $propsWithValues[$key] = $true }
            }
        } else {
            foreach ($prop in $item.PSObject.Properties) {
                if ($null -ne $prop.Value) { $propsWithValues[$prop.Name] = $true }
            }
        }
    }

    # Build column list: priority columns ALWAYS first, then the rest alphabetically
    $result = @()
    foreach ($col in $priorityColumns) {
        $result += $col
        $propsWithValues.Remove($col)  # Remove from remaining to avoid duplicates
    }
    # Add remaining columns alphabetically, excluding internal Cosmos fields and common noise
    $excludeFields = @('_rid', '_self', '_etag', '_attachments', '_ts', 'id', 'principalType', 'resourceType', 'edgeType', 'policyType', 'eventType')
    $remaining = $propsWithValues.Keys | Where-Object { $_ -notin $excludeFields -and $_ -notin $priorityColumns } | Sort-Object
    $result += $remaining

    return $result
}

function Build-Table {
    param($data, $tableId, $columns, $entityType = $null, $parentCount = $null)
    if ($null -eq $data -or $data.Count -eq 0) {
        # Provide diagnostic information for empty data
        $msg = if ($parentCount -eq 0) {
            # Parent container has no data at all
            '<p style="color:#999;padding:20px;font-size:0.85em;">No data in container - collection may not have run yet</p>'
        } elseif ($parentCount -gt 0) {
            # Parent has data but this filter returned nothing
            "<p style='color:#666;padding:20px;font-size:0.85em;'>No $entityType found (0 of $parentCount in container)</p>"
        } else {
            # Fallback - no context provided
            '<p style="color:#666;padding:20px;font-size:0.85em;">No data</p>'
        }
        return $msg
    }

    $headers = ($columns | ForEach-Object { "<th onclick=`"sortTable('$tableId', $($columns.IndexOf($_)))`">$_</th>" }) -join ""
    $rows = ($data | ForEach-Object {
        $item = $_
        $cells = ($columns | ForEach-Object {
            $val = if ($item -is [System.Collections.IDictionary]) { $item[$_] } else { $item.$_ }
            "<td>$(Format-Value $val)</td>"
        }) -join ""
        "<tr>$cells</tr>"
    }) -join "`n"

    return "<table id='$tableId'><thead><tr>$headers</tr></thead><tbody>$rows</tbody></table>"
}

try {
    # ========== CONTAINER 1: PRINCIPALS (users, groups, SPs, devices) ==========
    $allPrincipals = @($principalsIn | Where-Object { $_ })
    $users = @($allPrincipals | Where-Object { $_.principalType -eq 'user' })
    $groups = @($allPrincipals | Where-Object { $_.principalType -eq 'group' })
    $sps = @($allPrincipals | Where-Object { $_.principalType -eq 'servicePrincipal' })
    $devices = @($allPrincipals | Where-Object { $_.principalType -eq 'device' })
    $adminUnits = @($allPrincipals | Where-Object { $_.principalType -eq 'administrativeUnit' })

    # ========== CONTAINER 2: RESOURCES (applications + Azure resources + role definitions) ==========
    $allResources = @($resourcesIn | Where-Object { $_ })
    $apps = @($allResources | Where-Object { $_.resourceType -eq 'application' })
    $tenants = @($allResources | Where-Object { $_.resourceType -eq 'tenant' })
    $mgmtGroups = @($allResources | Where-Object { $_.resourceType -eq 'managementGroup' })
    $subscriptions = @($allResources | Where-Object { $_.resourceType -eq 'subscription' })

    # Enrich subscriptions with owner info from Azure RBAC edges
    # Owner role GUID: 8e3af657-a8ff-443c-a75c-2fe8c4bcb635
    $subscriptionOwners = @{}
    foreach ($edge in $edgesIn) {
        if ($null -eq $edge) { continue }
        if ($edge.edgeType -eq 'azureRbac' -and
            $edge.scopeType -eq 'subscription' -and
            $edge.targetRoleDefinitionId -and
            $edge.targetRoleDefinitionId -match '8e3af657-a8ff-443c-a75c-2fe8c4bcb635') {
            # Get subscription ID - prefer subscriptionId field, fall back to extracting from scope
            $subId = $edge.subscriptionId
            if (-not $subId -and $edge.scope -match '/subscriptions/([a-f0-9-]+)') {
                $subId = $Matches[1]
            }
            if (-not $subId) { continue }
            if (-not $subscriptionOwners.ContainsKey($subId)) {
                $subscriptionOwners[$subId] = @()
            }
            # Look up principal displayName
            $principalName = $edge.sourceDisplayName
            if (-not $principalName) {
                $principal = $allPrincipals | Where-Object { $_.objectId -eq $edge.sourceId } | Select-Object -First 1
                $principalName = if ($principal) { $principal.displayName ?? $principal.userPrincipalName ?? $edge.sourceId } else { $edge.sourceId }
            }
            $ownerInfo = "$principalName ($($edge.sourceType))"
            if ($ownerInfo -notin $subscriptionOwners[$subId]) {
                $subscriptionOwners[$subId] += $ownerInfo
            }
        }
    }
    # Add owners property to each subscription
    # Create deep copies to ensure mutability (Cosmos DB objects may be read-only)
    $enrichedSubscriptions = @()
    foreach ($sub in $subscriptions) {
        if ($null -eq $sub) { continue }
        $subId = $sub.subscriptionId ?? $sub.objectId
        # If objectId has path prefix, extract just the GUID
        if ($subId -match '/subscriptions/([a-f0-9-]+)') {
            $subId = $Matches[1]
        }
        # Convert to JSON and back to create a mutable deep copy
        $subCopy = $sub | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        # Add owners property
        $ownerValue = if ($subId -and $subscriptionOwners.ContainsKey($subId)) {
            ($subscriptionOwners[$subId] -join ', ')
        } else {
            $null
        }
        $subCopy | Add-Member -NotePropertyName 'owners' -NotePropertyValue $ownerValue -Force
        $enrichedSubscriptions += $subCopy
    }
    $subscriptions = $enrichedSubscriptions

    $resourceGroups = @($allResources | Where-Object { $_.resourceType -eq 'resourceGroup' })
    $keyVaults = @($allResources | Where-Object { $_.resourceType -eq 'keyVault' })
    $vms = @($allResources | Where-Object { $_.resourceType -eq 'virtualMachine' })
    $automationAccounts = @($allResources | Where-Object { $_.resourceType -eq 'automationAccount' })
    $functionApps = @($allResources | Where-Object { $_.resourceType -eq 'functionApp' })
    $logicApps = @($allResources | Where-Object { $_.resourceType -eq 'logicApp' })
    $webApps = @($allResources | Where-Object { $_.resourceType -eq 'webApp' })
    # V3.5: Additional Azure resources
    $storageAccounts = @($allResources | Where-Object { $_.resourceType -eq 'storageAccount' })
    $aksClusters = @($allResources | Where-Object { $_.resourceType -eq 'aksCluster' })
    $containerRegistries = @($allResources | Where-Object { $_.resourceType -eq 'containerRegistry' })
    $vmScaleSets = @($allResources | Where-Object { $_.resourceType -eq 'vmScaleSet' })
    $dataFactories = @($allResources | Where-Object { $_.resourceType -eq 'dataFactory' })
    # V3.5: Role definitions (consolidated)
    $directoryRoleDefs = @($allResources | Where-Object { $_.resourceType -eq 'directoryRoleDefinition' })
    $azureRoleDefs = @($allResources | Where-Object { $_.resourceType -eq 'azureRoleDefinition' })

    # ========== CONTAINER 3: EDGES (all relationships + derived edges) ==========
    $allEdges = @($edgesIn | Where-Object { $_ })
    $groupMembers = @($allEdges | Where-Object { $_.edgeType -match '^groupMember' })
    $directoryRoles = @($allEdges | Where-Object { $_.edgeType -eq 'directoryRole' })
    $pimRoles = @($allEdges | Where-Object { $_.edgeType -match '^pim(Eligible|Active)$' })
    $pimGroups = @($allEdges | Where-Object { $_.edgeType -match '^pimGroup' })
    $azureRbac = @($allEdges | Where-Object { $_.edgeType -eq 'azureRbac' -or $_.edgeType -eq 'azureRoleAssignment' })
    $appRoles = @($allEdges | Where-Object { $_.edgeType -eq 'appRoleAssignment' })
    $owners = @($allEdges | Where-Object { $_.edgeType -match 'Owner$' })
    $licenses = @($allEdges | Where-Object { $_.edgeType -eq 'license' })
    $contains = @($allEdges | Where-Object { $_.edgeType -eq 'contains' })
    $kvAccess = @($allEdges | Where-Object { $_.edgeType -eq 'keyVaultAccess' })
    $managedIdentities = @($allEdges | Where-Object { $_.edgeType -eq 'hasManagedIdentity' })
    $auMembers = @($allEdges | Where-Object { $_.edgeType -eq 'auMember' })
    # V3.5: Derived edges (from DeriveEdges function)
    $derivedEdges = @($allEdges | Where-Object { $_.edgeType -match '^can|^is|^azure' -and $_.derivedFrom })
    # V3.5: CA policy edges (caPolicyTargetsPrincipal, caPolicyTargetsApplication, caPolicyExcludesPrincipal, etc.)
    $caPolicyEdges = @($allEdges | Where-Object { $_.edgeType -match '^caPolicy' })
    # V3.5: Virtual edges (Intune policy targeting - compliancePolicyTargets, appProtectionPolicyTargets)
    $virtualEdges = @($allEdges | Where-Object { $_.edgeType -match 'compliancePolicy|appProtectionPolicy' })

    # ========== CONTAINER 4: POLICIES ==========
    $allPolicies = @($policiesIn | Where-Object { $_ })
    $caPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'conditionalAccess' })
    $rolePolicies = @($allPolicies | Where-Object { $_.policyType -match 'roleManagement' })
    # V3.5: Intune policies
    $compliancePolicies = @($allPolicies | Where-Object { $_.policyType -eq 'compliancePolicy' })
    $appProtectionPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'appProtectionPolicy' })
    $namedLocations = @($allPolicies | Where-Object { $_.policyType -eq 'namedLocation' })
    # V3.5 Phase 1: Security policies (Auth Methods, Security Defaults, Authorization)
    $authMethodsPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'authenticationMethodsPolicy' })
    $securityDefaultsPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'securityDefaults' })
    $authorizationPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'authorizationPolicy' })

    # ========== CONTAINER 5: AUDIT (Change Tracking) ==========
    $changes = @($auditIn | Where-Object { $_ })

    # Column definitions - priority columns shown first, then ALL other columns discovered dynamically
    # V3.5: Dynamic column discovery ensures all collected properties are visible
    $userPriority = @('objectId', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'perUserMfaState', 'authMethodCount', 'riskLevel', 'riskState', 'riskLastUpdatedDateTime', 'isAtRisk', 'hasP2License', 'hasE5License', 'licenseCount', 'assignedLicenseSkus', 'mail', 'jobTitle', 'department', 'createdDateTime', 'lastPasswordChangeDateTime', 'onPremisesSyncEnabled')
    $groupPriority = @('objectId', 'displayName', 'securityEnabled', 'groupTypes', 'groupTypeCategory', 'memberCountDirect', 'memberCountIndirect', 'memberCountTotal', 'userMemberCount', 'groupMemberCount', 'servicePrincipalMemberCount', 'deviceMemberCount', 'nestingDepth', 'isAssignableToRole', 'mail', 'visibility', 'createdDateTime', 'onPremisesSyncEnabled')
    $spPriority = @('objectId', 'displayName', 'appId', 'servicePrincipalType', 'accountEnabled', 'secretCount', 'certificateCount', 'createdDateTime', 'appOwnerOrganizationId')
    $devicePriority = @('objectId', 'displayName', 'deviceId', 'operatingSystem', 'operatingSystemVersion', 'isCompliant', 'isManaged', 'trustType', 'registrationDateTime', 'approximateLastSignInDateTime')
    $adminUnitPriority = @('objectId', 'displayName', 'description', 'membershipType', 'memberCountTotal', 'userMemberCount', 'groupMemberCount', 'deviceMemberCount', 'scopedRoleCount', 'membershipRule', 'isMemberManagementRestricted', 'visibility')
    $appPriority = @('objectId', 'displayName', 'appId', 'signInAudience', 'secretCount', 'certificateCount', 'createdDateTime', 'publisherDomain')
    $azureResPriority = @('objectId', 'displayName', 'resourceType', 'owners', 'location', 'subscriptionId', 'resourceGroup', 'kind', 'sku')
    $roleDefPriority = @('objectId', 'displayName', 'resourceType', 'isBuiltIn', 'isPrivileged', 'description')
    $edgePriority = @('id', 'sourceId', 'sourceDisplayName', 'edgeType', 'targetId', 'targetDisplayName', 'effectiveFrom', 'effectiveTo')
    $derivedEdgePriority = @('id', 'sourceId', 'sourceDisplayName', 'edgeType', 'targetId', 'targetDisplayName', 'derivedFrom', 'severity', 'capability')
    # Azure RBAC-specific columns with role name prominently displayed
    $azureRbacPriority = @('sourceDisplayName', 'sourceType', 'targetRoleDefinitionName', 'scope', 'scopeType', 'subscriptionName', 'resourceGroup', 'sourceId', 'targetRoleDefinitionId')
    $policyPriority = @('objectId', 'displayName', 'policyType', 'state', 'createdDateTime', 'modifiedDateTime')
    $intunePolicyPriority = @('objectId', 'displayName', 'policyType', 'platform', 'createdDateTime', 'lastModifiedDateTime')
    $namedLocPriority = @('objectId', 'displayName', 'policyType', 'locationType', 'isTrusted', 'createdDateTime')
    # V3.5 Phase 1: Security policy column priorities
    $authMethodsPriority = @('objectId', 'displayName', 'policyType', 'methodConfigurationCount', 'microsoftAuthenticatorEnabled', 'fido2Enabled', 'smsEnabled', 'temporaryAccessPassEnabled', 'policyMigrationState', 'lastModifiedDateTime')
    $securityDefaultsPriority = @('objectId', 'displayName', 'policyType', 'isEnabled', 'description')
    $authorizationPriority = @('objectId', 'displayName', 'policyType', 'guestUserRoleName', 'allowInvitesFrom', 'usersCanCreateApps', 'usersCanCreateGroups', 'usersCanCreateTenants', 'blockMsolPowerShell')
    $auditPriority = @('objectId', 'entityType', 'changeType', 'displayName', 'changeTimestamp', 'auditDate', 'changedFields', 'delta')

    # Dynamically get ALL columns from data, with priority columns first
    $userCols = Get-AllColumns $users $userPriority
    $groupCols = Get-AllColumns $groups $groupPriority
    $spCols = Get-AllColumns $sps $spPriority
    $deviceCols = Get-AllColumns $devices $devicePriority
    $adminUnitCols = Get-AllColumns $adminUnits $adminUnitPriority
    $appCols = Get-AllColumns $apps $appPriority
    $azureResCols = Get-AllColumns (@($tenants + $mgmtGroups + $subscriptions + $resourceGroups + $keyVaults + $vms + $storageAccounts + $aksClusters + $containerRegistries + $vmScaleSets + $functionApps + $logicApps + $webApps + $automationAccounts + $dataFactories) | Where-Object { $_ }) $azureResPriority
    # Subscription-specific columns (includes owners)
    $subsPriority = @('objectId', 'displayName', 'owners', 'subscriptionId', 'state', 'authorizationSource', 'tenantId')
    $subsCols = Get-AllColumns $subscriptions $subsPriority
    $roleDefCols = Get-AllColumns (@($directoryRoleDefs + $azureRoleDefs) | Where-Object { $_ }) $roleDefPriority
    $edgeCols = Get-AllColumns $allEdges $edgePriority
    $derivedEdgeCols = Get-AllColumns $derivedEdges $derivedEdgePriority
    $azureRbacCols = Get-AllColumns $azureRbac $azureRbacPriority
    $policyCols = Get-AllColumns $caPolicies $policyPriority
    $intunePolicyCols = Get-AllColumns (@($compliancePolicies + $appProtectionPolicies) | Where-Object { $_ }) $intunePolicyPriority
    $namedLocCols = Get-AllColumns $namedLocations $namedLocPriority
    # V3.5 Phase 1: Security policy columns
    $authMethodsCols = Get-AllColumns $authMethodsPolicies $authMethodsPriority
    $securityDefaultsCols = Get-AllColumns $securityDefaultsPolicies $securityDefaultsPriority
    $authorizationCols = Get-AllColumns $authorizationPolicies $authorizationPriority
    $auditCols = Get-AllColumns $changes $auditPriority

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Entra Risk Dashboard - V3.5</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f0f2f5; }
        h1 { color: #0078d4; margin: 0 0 15px 0; }
        .summary { background: #e3f2fd; padding: 12px 15px; border-radius: 6px; margin-bottom: 20px; border-left: 4px solid #0078d4; font-size: 0.9em; }
        .container { background: white; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .container-header { background: #0078d4; color: white; padding: 12px 20px; border-radius: 8px 8px 0 0; font-weight: bold; display: flex; align-items: center; gap: 10px; cursor: pointer; user-select: none; }
        .container-header:hover { background: #106ebe; }
        .container-header .chevron { transition: transform 0.2s; margin-right: 5px; }
        .container.collapsed .chevron { transform: rotate(-90deg); }
        .container.collapsed .container-header { border-radius: 8px; }
        .container-header .count { background: rgba(255,255,255,0.2); padding: 2px 8px; border-radius: 10px; font-size: 0.85em; }
        .container-header .desc { font-weight: normal; opacity: 0.85; font-size: 0.9em; margin-left: auto; }
        .container-body { overflow: hidden; transition: max-height 0.3s ease-out; }
        .container.collapsed .container-body { max-height: 0 !important; }
        .tabs { display: flex; flex-wrap: wrap; gap: 3px; padding: 10px 15px; background: #f8f9fa; border-bottom: 1px solid #e9ecef; }
        .tab { padding: 6px 12px; border: none; background: #e9ecef; cursor: pointer; border-radius: 4px; font-size: 0.85em; }
        .tab:hover { background: #dee2e6; }
        .tab.active { background: #0078d4; color: white; }
        .tab.derived { background: #ff8c00; color: white; }
        .tab.derived:hover { background: #e67e00; }
        .tab-content { display: none; padding: 0; overflow-x: auto; max-height: 600px; overflow-y: auto; }
        .tab-content.active { display: block; }
        table { width: max-content; min-width: 100%; border-collapse: collapse; font-size: 0.8em; }
        th { background: #f8f9fa; padding: 10px 8px; text-align: left; border-bottom: 2px solid #dee2e6; cursor: pointer; white-space: nowrap; font-weight: 600; position: sticky; top: 0; z-index: 1; }
        th:hover { background: #e9ecef; }
        td { padding: 8px; border-bottom: 1px solid #f0f0f0; white-space: nowrap; max-width: 300px; overflow: hidden; text-overflow: ellipsis; }
        tr:hover { background: #f8f9fa; }
        .risk-high { color: #d13438; font-weight: bold; }
        .risk-medium { color: #ff8c00; font-weight: bold; }
        .risk-low { color: #107c10; }
    </style>
    <script>
        function toggleContainer(containerId) {
            var container = document.getElementById(containerId);
            container.classList.toggle('collapsed');
        }
        function showTab(container, tabId, btn) {
            document.querySelectorAll('#' + container + ' .tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('#' + container + ' .tab').forEach(b => b.classList.remove('active'));
            document.getElementById(tabId).classList.add('active');
            btn.classList.add('active');
        }
        function sortTable(tableId, col) {
            var table = document.getElementById(tableId);
            if (!table) return;
            var rows = Array.from(table.querySelectorAll('tbody tr'));
            var asc = table.dataset.sortCol != col || table.dataset.sortDir != 'asc';
            rows.sort((a, b) => {
                var av = a.cells[col]?.textContent || '';
                var bv = b.cells[col]?.textContent || '';
                return asc ? av.localeCompare(bv) : bv.localeCompare(av);
            });
            rows.forEach(r => table.querySelector('tbody').appendChild(r));
            table.dataset.sortCol = col;
            table.dataset.sortDir = asc ? 'asc' : 'desc';
        }
    </script>
</head>
<body>
    <h1>Entra Risk Dashboard - V3.5</h1>
    <div class="summary">
        <b>V3.5 Consolidated Architecture</b> |
        Principals: <b>$($allPrincipals.Count)</b> |
        Resources: <b>$($allResources.Count)</b> |
        Edges: <b>$($allEdges.Count)</b> (Derived: $($derivedEdges.Count)) |
        Policies: <b>$($allPolicies.Count)</b> |
        Audit: <b>$($changes.Count)</b> |
        <span style="color:#666">$(Get-Date -Format 'yyyy-MM-dd HH:mm')</span>
    </div>

    <!-- CONTAINER 1: PRINCIPALS -->
    <div class="container" id="principals-section">
        <div class="container-header" onclick="toggleContainer('principals-section')">
            <span class="chevron">&#9660;</span>
            PRINCIPALS <span class="count">$($allPrincipals.Count)</span>
            <span class="desc">users (with risk), groups, service principals, devices</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('principals-section', 'users-tab', this)">Users ($($users.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'groups-tab', this)">Groups ($($groups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'sps-tab', this)">Service Principals ($($sps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'devices-tab', this)">Devices ($($devices.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'au-tab', this)">Admin Units ($($adminUnits.Count))</button>
            </div>
            <div id="users-tab" class="tab-content active">$(Build-Table $users 'users-tbl' $userCols 'users' $allPrincipals.Count)</div>
            <div id="groups-tab" class="tab-content">$(Build-Table $groups 'groups-tbl' $groupCols 'groups' $allPrincipals.Count)</div>
            <div id="sps-tab" class="tab-content">$(Build-Table $sps 'sps-tbl' $spCols 'service principals' $allPrincipals.Count)</div>
            <div id="devices-tab" class="tab-content">$(Build-Table $devices 'devices-tbl' $deviceCols 'devices' $allPrincipals.Count)</div>
            <div id="au-tab" class="tab-content">$(Build-Table $adminUnits 'au-tbl' $adminUnitCols 'administrative units' $allPrincipals.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 2: RESOURCES -->
    <div class="container" id="resources-section">
        <div class="container-header" onclick="toggleContainer('resources-section')">
            <span class="chevron">&#9660;</span>
            RESOURCES <span class="count">$($allResources.Count)</span>
            <span class="desc">applications + Azure resources + role definitions</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('resources-section', 'apps-tab', this)">Applications ($($apps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'tenants-tab', this)">Tenants ($($tenants.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'mgmt-tab', this)">Mgmt Groups ($($mgmtGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'subs-tab', this)">Subscriptions ($($subscriptions.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'rgs-tab', this)">Resource Groups ($($resourceGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'kvs-tab', this)">Key Vaults ($($keyVaults.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'vms-tab', this)">VMs ($($vms.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'storage-tab', this)">Storage ($($storageAccounts.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'aks-tab', this)">AKS ($($aksClusters.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'acr-tab', this)">ACR ($($containerRegistries.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'vmss-tab', this)">VMSS ($($vmScaleSets.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'funcs-tab', this)">Functions ($($functionApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'logic-tab', this)">Logic Apps ($($logicApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'web-tab', this)">Web Apps ($($webApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'auto-tab', this)">Automation ($($automationAccounts.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'adf-tab', this)">Data Factory ($($dataFactories.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'dirroles-tab', this)">Dir Roles ($($directoryRoleDefs.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'azroles-tab', this)">Azure Roles ($($azureRoleDefs.Count))</button>
            </div>
            <div id="apps-tab" class="tab-content active">$(Build-Table $apps 'apps-tbl' $appCols 'applications' $allResources.Count)</div>
            <div id="tenants-tab" class="tab-content">$(Build-Table $tenants 'tenants-tbl' $azureResCols 'tenants' $allResources.Count)</div>
            <div id="mgmt-tab" class="tab-content">$(Build-Table $mgmtGroups 'mgmt-tbl' $azureResCols 'management groups' $allResources.Count)</div>
            <div id="subs-tab" class="tab-content">$(Build-Table $subscriptions 'subs-tbl' $subsCols 'subscriptions' $allResources.Count)</div>
            <div id="rgs-tab" class="tab-content">$(Build-Table $resourceGroups 'rgs-tbl' $azureResCols 'resource groups' $allResources.Count)</div>
            <div id="kvs-tab" class="tab-content">$(Build-Table $keyVaults 'kvs-tbl' $azureResCols 'key vaults' $allResources.Count)</div>
            <div id="vms-tab" class="tab-content">$(Build-Table $vms 'vms-tbl' $azureResCols 'virtual machines' $allResources.Count)</div>
            <div id="storage-tab" class="tab-content">$(Build-Table $storageAccounts 'storage-tbl' $azureResCols 'storage accounts' $allResources.Count)</div>
            <div id="aks-tab" class="tab-content">$(Build-Table $aksClusters 'aks-tbl' $azureResCols 'AKS clusters' $allResources.Count)</div>
            <div id="acr-tab" class="tab-content">$(Build-Table $containerRegistries 'acr-tbl' $azureResCols 'container registries' $allResources.Count)</div>
            <div id="vmss-tab" class="tab-content">$(Build-Table $vmScaleSets 'vmss-tbl' $azureResCols 'VM scale sets' $allResources.Count)</div>
            <div id="funcs-tab" class="tab-content">$(Build-Table $functionApps 'funcs-tbl' $azureResCols 'function apps' $allResources.Count)</div>
            <div id="logic-tab" class="tab-content">$(Build-Table $logicApps 'logic-tbl' $azureResCols 'logic apps' $allResources.Count)</div>
            <div id="web-tab" class="tab-content">$(Build-Table $webApps 'web-tbl' $azureResCols 'web apps' $allResources.Count)</div>
            <div id="auto-tab" class="tab-content">$(Build-Table $automationAccounts 'auto-tbl' $azureResCols 'automation accounts' $allResources.Count)</div>
            <div id="adf-tab" class="tab-content">$(Build-Table $dataFactories 'adf-tbl' $azureResCols 'data factories' $allResources.Count)</div>
            <div id="dirroles-tab" class="tab-content">$(Build-Table $directoryRoleDefs 'dirroles-tbl' $roleDefCols 'directory role definitions' $allResources.Count)</div>
            <div id="azroles-tab" class="tab-content">$(Build-Table $azureRoleDefs 'azroles-tbl' $roleDefCols 'Azure role definitions' $allResources.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 3: EDGES -->
    <div class="container" id="edges-section">
        <div class="container-header" onclick="toggleContainer('edges-section')">
            <span class="chevron">&#9660;</span>
            EDGES <span class="count">$($allEdges.Count)</span>
            <span class="desc">relationships + paths</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('edges-section', 'gm-tab', this)">Group Members ($($groupMembers.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'dr-tab', this)">Directory Roles ($($directoryRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'pimr-tab', this)">PIM Roles ($($pimRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'pimg-tab', this)">PIM Groups ($($pimGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'rbac-tab', this)">Azure RBAC ($($azureRbac.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ar-tab', this)">App Roles ($($appRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'own-tab', this)">Owners ($($owners.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'lic-tab', this)">Licenses ($($licenses.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'cnt-tab', this)">Contains ($($contains.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'kva-tab', this)">KV Access ($($kvAccess.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'mi-tab', this)">Managed Identity ($($managedIdentities.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'aum-tab', this)">AU Members ($($auMembers.Count))</button>
                <button class="tab derived" onclick="event.stopPropagation(); showTab('edges-section', 'derived-tab', this)">Derived ($($derivedEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ca-edge-tab', this)">CA Policy ($($caPolicyEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'virtual-tab', this)">Intune Policy ($($virtualEdges.Count))</button>
            </div>
            <div id="gm-tab" class="tab-content active">$(Build-Table $groupMembers 'gm-tbl' $edgeCols 'group memberships' $allEdges.Count)</div>
            <div id="dr-tab" class="tab-content">$(Build-Table $directoryRoles 'dr-tbl' $edgeCols 'directory role assignments' $allEdges.Count)</div>
            <div id="pimr-tab" class="tab-content">$(Build-Table $pimRoles 'pimr-tbl' $edgeCols 'PIM role assignments' $allEdges.Count)</div>
            <div id="pimg-tab" class="tab-content">$(Build-Table $pimGroups 'pimg-tbl' $edgeCols 'PIM group assignments' $allEdges.Count)</div>
            <div id="rbac-tab" class="tab-content">$(Build-Table $azureRbac 'rbac-tbl' $azureRbacCols 'Azure RBAC assignments' $allEdges.Count)</div>
            <div id="ar-tab" class="tab-content">$(Build-Table $appRoles 'ar-tbl' $edgeCols 'app role assignments' $allEdges.Count)</div>
            <div id="own-tab" class="tab-content">$(Build-Table $owners 'own-tbl' $edgeCols 'ownership edges' $allEdges.Count)</div>
            <div id="lic-tab" class="tab-content">$(Build-Table $licenses 'lic-tbl' $edgeCols 'license assignments' $allEdges.Count)</div>
            <div id="cnt-tab" class="tab-content">$(Build-Table $contains 'cnt-tbl' $edgeCols 'containment edges' $allEdges.Count)</div>
            <div id="kva-tab" class="tab-content">$(Build-Table $kvAccess 'kva-tbl' $edgeCols 'Key Vault access' $allEdges.Count)</div>
            <div id="mi-tab" class="tab-content">$(Build-Table $managedIdentities 'mi-tbl' $edgeCols 'managed identity edges' $allEdges.Count)</div>
            <div id="aum-tab" class="tab-content">$(Build-Table $auMembers 'aum-tbl' $edgeCols 'AU membership edges' $allEdges.Count)</div>
            <div id="derived-tab" class="tab-content">$(Build-Table $derivedEdges 'derived-tbl' $derivedEdgeCols 'derived abuse edges' $allEdges.Count)</div>
            <div id="ca-edge-tab" class="tab-content">$(Build-Table $caPolicyEdges 'ca-edge-tbl' $edgeCols 'CA policy edges' $allEdges.Count)</div>
            <div id="virtual-tab" class="tab-content">$(Build-Table $virtualEdges 'virtual-tbl' $edgeCols 'Intune policy edges' $allEdges.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 4: POLICIES -->
    <div class="container" id="policies-section">
        <div class="container-header" onclick="toggleContainer('policies-section')">
            <span class="chevron">&#9660;</span>
            POLICIES <span class="count">$($allPolicies.Count)</span>
            <span class="desc">CA, Intune, security policies, named locations</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('policies-section', 'ca-tab', this)">Conditional Access ($($caPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'rp-tab', this)">Role Policies ($($rolePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'compliance-tab', this)">Compliance ($($compliancePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'appprot-tab', this)">App Protection ($($appProtectionPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'namedloc-tab', this)">Named Locations ($($namedLocations.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'authmethods-tab', this)">Auth Methods ($($authMethodsPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'secdefaults-tab', this)">Security Defaults ($($securityDefaultsPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'authz-tab', this)">Authorization ($($authorizationPolicies.Count))</button>
            </div>
            <div id="ca-tab" class="tab-content active">$(Build-Table $caPolicies 'ca-tbl' $policyCols 'CA policies' $allPolicies.Count)</div>
            <div id="rp-tab" class="tab-content">$(Build-Table $rolePolicies 'rp-tbl' $policyCols 'role policies' $allPolicies.Count)</div>
            <div id="compliance-tab" class="tab-content">$(Build-Table $compliancePolicies 'compliance-tbl' $intunePolicyCols 'compliance policies' $allPolicies.Count)</div>
            <div id="appprot-tab" class="tab-content">$(Build-Table $appProtectionPolicies 'appprot-tbl' $intunePolicyCols 'app protection policies' $allPolicies.Count)</div>
            <div id="namedloc-tab" class="tab-content">$(Build-Table $namedLocations 'namedloc-tbl' $namedLocCols 'named locations' $allPolicies.Count)</div>
            <div id="authmethods-tab" class="tab-content">$(Build-Table $authMethodsPolicies 'authmethods-tbl' $authMethodsCols 'authentication methods policy' $allPolicies.Count)</div>
            <div id="secdefaults-tab" class="tab-content">$(Build-Table $securityDefaultsPolicies 'secdefaults-tbl' $securityDefaultsCols 'security defaults policy' $allPolicies.Count)</div>
            <div id="authz-tab" class="tab-content">$(Build-Table $authorizationPolicies 'authz-tbl' $authorizationCols 'authorization policy' $allPolicies.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 5: HISTORICAL CHANGES (Delta Tracking) -->
    <div class="container" id="audit-section">
        <div class="container-header" onclick="toggleContainer('audit-section')">
            <span class="chevron">&#9660;</span>
            HISTORICAL CHANGES <span class="count">$($changes.Count)</span>
            <span class="desc">delta tracking - new, modified, deleted entities</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('audit-section', 'changes-tab', this)">All Changes ($($changes.Count))</button>
            </div>
            <div id="changes-tab" class="tab-content active">$(Build-Table $changes 'changes-tbl' $auditCols 'historical changes' $changes.Count)</div>
        </div>
    </div>

</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Body = $html
        Headers = @{ "content-type" = "text/html" }
    })
} catch {
    Write-Error "Dashboard error: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body = "Error: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    })
}
