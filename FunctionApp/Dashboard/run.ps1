using namespace System.Net

# V3.5 Dashboard - 6 Unified Containers + Derived Edges
# 1. principals (users, groups, SPs, devices)
# 2. resources (applications + Azure resources + role definitions)
# 3. edges (all relationships + derived edges)
# 4. policies (CA, Intune compliance, App Protection, Named Locations)
# 5. events (sign-ins, audits)
# 6. audit (change tracking)

# Azure Functions runtime passes these parameters - not all are used in this function
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Request', Justification = 'Required by Azure Functions runtime')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TriggerMetadata', Justification = 'Required by Azure Functions runtime')]
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
    param($value)
    if ($null -eq $value) { return '<span style="color:#999">null</span>' }
    if ($value -is [bool]) { if ($value) { return '<span style="color:#107c10">true</span>' } else { return '<span style="color:#d13438">false</span>' } }
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return '[]' }
        if ($value.Count -le 3) { return "[" + ($value -join ", ") + "]" }
        return "[$($value.Count) items]"
    }
    if ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject]) { return '{...}' }
    return [System.Web.HttpUtility]::HtmlEncode($value)
}

function Build-Table {
    param($data, $tableId, $columns)
    if ($null -eq $data -or $data.Count -eq 0) { return '<p style="color:#666;padding:20px;">No data</p>' }

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

    # ========== CONTAINER 2: RESOURCES (applications + Azure resources + role definitions) ==========
    $allResources = @($resourcesIn | Where-Object { $_ })
    $apps = @($allResources | Where-Object { $_.resourceType -eq 'application' })
    $tenants = @($allResources | Where-Object { $_.resourceType -eq 'tenant' })
    $mgmtGroups = @($allResources | Where-Object { $_.resourceType -eq 'managementGroup' })
    $subscriptions = @($allResources | Where-Object { $_.resourceType -eq 'subscription' })
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
    # V3.5: Derived edges (from DeriveEdges function)
    $derivedEdges = @($allEdges | Where-Object { $_.edgeType -match '^can|^is|^azure' -and $_.derivedFrom })
    # V3.5: CA policy edges
    $caPolicyEdges = @($allEdges | Where-Object { $_.edgeType -match 'conditionalAccessPolicy' })
    # V3.5: Virtual edges (Intune policy targeting)
    $virtualEdges = @($allEdges | Where-Object { $_.edgeType -match 'PolicyTargets$' })

    # ========== CONTAINER 4: POLICIES ==========
    $allPolicies = @($policiesIn | Where-Object { $_ })
    $caPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'conditionalAccess' })
    $rolePolicies = @($allPolicies | Where-Object { $_.policyType -match 'roleManagement' })
    # V3.5: Intune policies
    $compliancePolicies = @($allPolicies | Where-Object { $_.policyType -eq 'compliancePolicy' })
    $appProtectionPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'appProtectionPolicy' })
    $namedLocations = @($allPolicies | Where-Object { $_.policyType -eq 'namedLocation' })

    # ========== CONTAINER 5: EVENTS ==========
    $allEvents = @($eventsIn | Where-Object { $_ })
    $signIns = @($allEvents | Where-Object { $_.eventType -eq 'signIn' })
    $auditEvents = @($allEvents | Where-Object { $_.eventType -eq 'audit' })

    # ========== CONTAINER 6: AUDIT ==========
    $changes = @($auditIn | Where-Object { $_ })

    # Column definitions
    # V3.5: Users now include risk data columns
    $userCols = @('objectId', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'perUserMfaState', 'authMethodCount', 'riskLevel', 'riskState', 'isAtRisk')
    $groupCols = @('objectId', 'displayName', 'securityEnabled', 'groupTypes', 'memberCountDirect', 'isAssignableToRole')
    $spCols = @('objectId', 'displayName', 'appId', 'servicePrincipalType', 'accountEnabled', 'secretCount', 'certificateCount')
    $deviceCols = @('objectId', 'displayName', 'deviceId', 'operatingSystem', 'isCompliant', 'isManaged')
    $appCols = @('objectId', 'displayName', 'appId', 'signInAudience', 'secretCount', 'certificateCount')
    $azureResCols = @('objectId', 'displayName', 'resourceType', 'location', 'subscriptionId')
    $roleDefCols = @('objectId', 'displayName', 'resourceType', 'isBuiltIn', 'isPrivileged')
    $edgeCols = @('id', 'sourceDisplayName', 'edgeType', 'targetDisplayName', 'effectiveFrom')
    $derivedEdgeCols = @('id', 'sourceDisplayName', 'edgeType', 'targetDisplayName', 'derivedFrom', 'severity')
    $policyCols = @('objectId', 'displayName', 'policyType', 'state')
    $intunePolicyCols = @('objectId', 'displayName', 'policyType', 'platform')
    $namedLocCols = @('objectId', 'displayName', 'policyType', 'locationType', 'isTrusted')
    $eventCols = @('id', 'eventType', 'createdDateTime', 'userPrincipalName')
    $auditCols = @('objectId', 'entityType', 'changeType', 'displayName', 'changeTimestamp')

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
        .tab-content { display: none; padding: 0; overflow-x: auto; }
        .tab-content.active { display: block; }
        table { width: 100%; border-collapse: collapse; font-size: 0.8em; }
        th { background: #f8f9fa; padding: 10px 8px; text-align: left; border-bottom: 2px solid #dee2e6; cursor: pointer; white-space: nowrap; font-weight: 600; }
        th:hover { background: #e9ecef; }
        td { padding: 8px; border-bottom: 1px solid #f0f0f0; }
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
        Events: <b>$($allEvents.Count)</b> |
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
            </div>
            <div id="users-tab" class="tab-content active">$(Build-Table $users 'users-tbl' $userCols)</div>
            <div id="groups-tab" class="tab-content">$(Build-Table $groups 'groups-tbl' $groupCols)</div>
            <div id="sps-tab" class="tab-content">$(Build-Table $sps 'sps-tbl' $spCols)</div>
            <div id="devices-tab" class="tab-content">$(Build-Table $devices 'devices-tbl' $deviceCols)</div>
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
            <div id="apps-tab" class="tab-content active">$(Build-Table $apps 'apps-tbl' $appCols)</div>
            <div id="tenants-tab" class="tab-content">$(Build-Table $tenants 'tenants-tbl' $azureResCols)</div>
            <div id="mgmt-tab" class="tab-content">$(Build-Table $mgmtGroups 'mgmt-tbl' $azureResCols)</div>
            <div id="subs-tab" class="tab-content">$(Build-Table $subscriptions 'subs-tbl' $azureResCols)</div>
            <div id="rgs-tab" class="tab-content">$(Build-Table $resourceGroups 'rgs-tbl' $azureResCols)</div>
            <div id="kvs-tab" class="tab-content">$(Build-Table $keyVaults 'kvs-tbl' $azureResCols)</div>
            <div id="vms-tab" class="tab-content">$(Build-Table $vms 'vms-tbl' $azureResCols)</div>
            <div id="storage-tab" class="tab-content">$(Build-Table $storageAccounts 'storage-tbl' $azureResCols)</div>
            <div id="aks-tab" class="tab-content">$(Build-Table $aksClusters 'aks-tbl' $azureResCols)</div>
            <div id="acr-tab" class="tab-content">$(Build-Table $containerRegistries 'acr-tbl' $azureResCols)</div>
            <div id="vmss-tab" class="tab-content">$(Build-Table $vmScaleSets 'vmss-tbl' $azureResCols)</div>
            <div id="funcs-tab" class="tab-content">$(Build-Table $functionApps 'funcs-tbl' $azureResCols)</div>
            <div id="logic-tab" class="tab-content">$(Build-Table $logicApps 'logic-tbl' $azureResCols)</div>
            <div id="web-tab" class="tab-content">$(Build-Table $webApps 'web-tbl' $azureResCols)</div>
            <div id="auto-tab" class="tab-content">$(Build-Table $automationAccounts 'auto-tbl' $azureResCols)</div>
            <div id="adf-tab" class="tab-content">$(Build-Table $dataFactories 'adf-tbl' $azureResCols)</div>
            <div id="dirroles-tab" class="tab-content">$(Build-Table $directoryRoleDefs 'dirroles-tbl' $roleDefCols)</div>
            <div id="azroles-tab" class="tab-content">$(Build-Table $azureRoleDefs 'azroles-tbl' $roleDefCols)</div>
        </div>
    </div>

    <!-- CONTAINER 3: EDGES -->
    <div class="container" id="edges-section">
        <div class="container-header" onclick="toggleContainer('edges-section')">
            <span class="chevron">&#9660;</span>
            EDGES <span class="count">$($allEdges.Count)</span>
            <span class="desc">all relationships + derived attack paths</span>
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
                <button class="tab derived" onclick="event.stopPropagation(); showTab('edges-section', 'derived-tab', this)">Derived ($($derivedEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ca-edge-tab', this)">CA Policy ($($caPolicyEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'virtual-tab', this)">Intune Policy ($($virtualEdges.Count))</button>
            </div>
            <div id="gm-tab" class="tab-content active">$(Build-Table $groupMembers 'gm-tbl' $edgeCols)</div>
            <div id="dr-tab" class="tab-content">$(Build-Table $directoryRoles 'dr-tbl' $edgeCols)</div>
            <div id="pimr-tab" class="tab-content">$(Build-Table $pimRoles 'pimr-tbl' $edgeCols)</div>
            <div id="pimg-tab" class="tab-content">$(Build-Table $pimGroups 'pimg-tbl' $edgeCols)</div>
            <div id="rbac-tab" class="tab-content">$(Build-Table $azureRbac 'rbac-tbl' $edgeCols)</div>
            <div id="ar-tab" class="tab-content">$(Build-Table $appRoles 'ar-tbl' $edgeCols)</div>
            <div id="own-tab" class="tab-content">$(Build-Table $owners 'own-tbl' $edgeCols)</div>
            <div id="lic-tab" class="tab-content">$(Build-Table $licenses 'lic-tbl' $edgeCols)</div>
            <div id="cnt-tab" class="tab-content">$(Build-Table $contains 'cnt-tbl' $edgeCols)</div>
            <div id="kva-tab" class="tab-content">$(Build-Table $kvAccess 'kva-tbl' $edgeCols)</div>
            <div id="mi-tab" class="tab-content">$(Build-Table $managedIdentities 'mi-tbl' $edgeCols)</div>
            <div id="derived-tab" class="tab-content">$(Build-Table $derivedEdges 'derived-tbl' $derivedEdgeCols)</div>
            <div id="ca-edge-tab" class="tab-content">$(Build-Table $caPolicyEdges 'ca-edge-tbl' $edgeCols)</div>
            <div id="virtual-tab" class="tab-content">$(Build-Table $virtualEdges 'virtual-tbl' $edgeCols)</div>
        </div>
    </div>

    <!-- CONTAINER 4: POLICIES -->
    <div class="container" id="policies-section">
        <div class="container-header" onclick="toggleContainer('policies-section')">
            <span class="chevron">&#9660;</span>
            POLICIES <span class="count">$($allPolicies.Count)</span>
            <span class="desc">CA, Intune compliance, app protection, named locations</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('policies-section', 'ca-tab', this)">Conditional Access ($($caPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'rp-tab', this)">Role Policies ($($rolePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'compliance-tab', this)">Compliance ($($compliancePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'appprot-tab', this)">App Protection ($($appProtectionPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'namedloc-tab', this)">Named Locations ($($namedLocations.Count))</button>
            </div>
            <div id="ca-tab" class="tab-content active">$(Build-Table $caPolicies 'ca-tbl' $policyCols)</div>
            <div id="rp-tab" class="tab-content">$(Build-Table $rolePolicies 'rp-tbl' $policyCols)</div>
            <div id="compliance-tab" class="tab-content">$(Build-Table $compliancePolicies 'compliance-tbl' $intunePolicyCols)</div>
            <div id="appprot-tab" class="tab-content">$(Build-Table $appProtectionPolicies 'appprot-tbl' $intunePolicyCols)</div>
            <div id="namedloc-tab" class="tab-content">$(Build-Table $namedLocations 'namedloc-tbl' $namedLocCols)</div>
        </div>
    </div>

    <!-- CONTAINER 5: EVENTS -->
    <div class="container" id="events-section">
        <div class="container-header" onclick="toggleContainer('events-section')">
            <span class="chevron">&#9660;</span>
            EVENTS <span class="count">$($allEvents.Count)</span>
            <span class="desc">sign-ins, audit logs (90 day TTL)</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('events-section', 'si-tab', this)">Sign-Ins ($($signIns.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('events-section', 'ae-tab', this)">Audit Events ($($auditEvents.Count))</button>
            </div>
            <div id="si-tab" class="tab-content active">$(Build-Table $signIns 'si-tbl' $eventCols)</div>
            <div id="ae-tab" class="tab-content">$(Build-Table $auditEvents 'ae-tbl' $eventCols)</div>
        </div>
    </div>

    <!-- CONTAINER 6: AUDIT -->
    <div class="container" id="audit-section">
        <div class="container-header" onclick="toggleContainer('audit-section')">
            <span class="chevron">&#9660;</span>
            AUDIT <span class="count">$($changes.Count)</span>
            <span class="desc">change tracking (permanent)</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('audit-section', 'changes-tab', this)">Changes ($($changes.Count))</button>
            </div>
            <div id="changes-tab" class="tab-content active">$(Build-Table $changes 'changes-tbl' $auditCols)</div>
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
