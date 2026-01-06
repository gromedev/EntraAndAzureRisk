using namespace System.Net

param(
    $Request,
    $TriggerMetadata,
    # Existing entities
    $usersRawIn,
    $groupsRawIn,
    $servicePrincipalsRawIn,
    $userChangesIn,
    $groupChangesIn,
    $servicePrincipalChangesIn,
    # New entities
    $riskyUsersRawIn,
    $riskyUserChangesIn,
    $devicesRawIn,
    $deviceChangesIn,
    $caPoliciesRawIn,
    $caPolicyChangesIn,
    $appRegsRawIn,
    $appRegChangesIn,
    $authMethodsRawIn,
    $authMethodChangesIn,
    $directoryRolesRawIn,
    $directoryRoleChangesIn,
    # Event data
    $signInLogsIn,
    $directoryAuditsIn,
    # PIM data
    $pimRolesRawIn,
    $pimRoleChangesIn,
    $pimGroupsRawIn,
    $pimGroupChangesIn,
    $rolePoliciesRawIn,
    $rolePolicyChangesIn,
    $azureRbacRawIn,
    $azureRbacChangesIn
)

Add-Type -AssemblyName System.Web
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

# Helper: Get dynamic properties with smart ordering
function Get-DynamicProperties {
    param($dataArray, [string]$dataType = "")

    if ($null -eq $dataArray -or $dataArray.Count -eq 0) { return @() }

    # Collect all unique property names (excluding Cosmos DB internals)
    $allProps = $dataArray | ForEach-Object {
        if ($_ -is [System.Collections.IDictionary]) { $_.Keys }
        else { $_.PSObject.Properties.Name }
    } | Where-Object { $_ -notmatch '^_' } | Select-Object -Unique | Sort-Object

    # Smart ordering based on data type
    $priority = if ($dataType -eq "changes") {
        @('Category', 'displayName', 'objectId')
    } elseif ($dataType -eq "risky") {
        @('objectId', 'userPrincipalName', 'riskLevel', 'riskState')
    } elseif ($dataType -eq "device") {
        @('objectId', 'displayName', 'isCompliant', 'isManaged', 'trustType')
    } elseif ($dataType -eq "policy") {
        @('objectId', 'displayName', 'state')
    } elseif ($dataType -eq "app") {
        @('objectId', 'displayName', 'appId', 'credentialStatus')
    } elseif ($dataType -eq "auth") {
        @('objectId', 'userPrincipalName', 'hasMfa', 'methodTypes')
    } elseif ($dataType -eq "role") {
        @('objectId', 'displayName', 'isPrivileged', 'memberCount')
    } elseif ($dataType -eq "pimrole") {
        @('objectId', 'principalDisplayName', 'roleDefinitionName', 'assignmentType', 'memberType', 'status')
    } elseif ($dataType -eq "pimgroup") {
        @('objectId', 'principalDisplayName', 'groupDisplayName', 'accessId', 'assignmentType', 'memberType', 'status')
    } elseif ($dataType -eq "rolepolicy") {
        @('objectId', 'displayName', 'scopeType', 'scopeId')
    } elseif ($dataType -eq "rbac") {
        @('objectId', 'principalType', 'roleDefinitionName', 'scope', 'scopeType')
    } elseif ($dataType -eq "signin") {
        @('id', 'userPrincipalName', 'status', 'riskLevelAggregated', 'createdDateTime')
    } elseif ($dataType -eq "audit") {
        @('id', 'activityDisplayName', 'category', 'initiatedBy', 'activityDateTime')
    } else {
        @('objectId', 'displayName')
    }

    return ($priority | Where-Object { $_ -in $allProps }) + ($allProps | Where-Object { $_ -notin $priority })
}

# Helper: Format value for display
function Format-DisplayValue {
    param($value, $propertyName)

    if ($null -eq $value) { return "<span class='no-data'>null</span>" }
    if ($value -is [bool]) { return $value.ToString() }

    # Handle arrays (including arrays of objects)
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return "[]" }

        # Check if array contains objects/hashtables
        $firstItem = $value[0]
        if ($firstItem -is [System.Collections.IDictionary] -or $firstItem -is [PSCustomObject]) {
            # Array of objects - format each object
            $formattedItems = $value | ForEach-Object {
                $currentObj = $_
                $objProps = if ($currentObj -is [System.Collections.IDictionary]) { $currentObj.Keys } else { $currentObj.PSObject.Properties.Name }
                $propPairs = $objProps | ForEach-Object {
                    $propName = $_
                    $propValue = if ($currentObj -is [System.Collections.IDictionary]) { $currentObj[$propName] } else { $currentObj.$propName }
                    $propDisplay = if ($null -eq $propValue) { "null" } else { [System.Web.HttpUtility]::HtmlEncode($propValue.ToString()) }
                    "<b>$propName</b> $propDisplay"
                }
                "<div style='margin:4px 0;padding:4px;background:#f5f5f5;border-radius:3px;'>$($propPairs -join '; ')</div>"
            }
            return "<div style='font-size:0.85em;'>$($formattedItems -join '')</div>"
        } else {
            # Array of simple values
            return "[" + ($value -join ", ") + "]"
        }
    }

    # Handle objects/hashtables
    if ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject]) {
        $props = if ($value -is [System.Collections.IDictionary]) { $value.Keys } else { $value.PSObject.Properties.Name }
        $maxDisplay = 888
        $items = $props | Select-Object -First $maxDisplay | ForEach-Object {
            $pValue = if ($value -is [System.Collections.IDictionary]) { $value[$_] } else { $value.$_ }
            $displayValue = if ($null -eq $pValue) { "null" } else { [System.Web.HttpUtility]::HtmlEncode($pValue.ToString()) }
            "<div><b>$_ </b> $displayValue</div>"
        }
        if ($props.Count -gt $maxDisplay) { $items += "<div style='color:#666;font-style:italic;'>... +$($props.Count - $maxDisplay) more</div>" }
        return "<div style='font-size:0.85em;'>$($items -join '')</div>"
    }

    # Handle dates
    if ($propertyName -match 'DateTime|Timestamp') {
        try { return ([DateTime]::Parse($value)).ToString("yyyy-MM-dd HH:mm") }
        catch { }
    }

    # Color-code risk levels
    if ($propertyName -eq 'riskLevel' -or $propertyName -eq 'riskLevelAggregated') {
        $color = switch ($value) {
            'high' { '#d13438' }
            'medium' { '#ff8c00' }
            'low' { '#107c10' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    # Color-code credential status
    if ($propertyName -eq 'credentialStatus') {
        $color = switch ($value) {
            'expired' { '#d13438' }
            'expiring_soon' { '#ff8c00' }
            'active' { '#107c10' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    # Color-code policy state
    if ($propertyName -eq 'state') {
        $color = switch ($value) {
            'enabled' { '#107c10' }
            'disabled' { '#d13438' }
            'enabledForReportingButNotEnforced' { '#ff8c00' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    return [System.Web.HttpUtility]::HtmlEncode($value)
}

# Helper: Render delta changes
function Format-Delta {
    param($delta)
    if ($null -eq $delta -or $delta.PSObject.Properties.Count -eq 0) { return "---" }
    ($delta.PSObject.Properties | ForEach-Object {
        $old = if ($null -eq $_.Value.old) { "null" } else { $_.Value.old }
        $new = if ($null -eq $_.Value.new) { "null" } else { $_.Value.new }
        "<div class='delta-item'><b>$($_.Name)</b>: <span class='delta-old'>$old</span> -> <span class='delta-new'>$new</span></div>"
    }) -join ''
}

# Helper: De-duplicate by objectId (keep latest)
function Remove-Duplicates {
    param($dataArray)
    if ($null -eq $dataArray -or $dataArray.Count -eq 0) { return @() }

    $unique = @{}
    foreach ($item in $dataArray) {
        $objectId = if ($item -is [System.Collections.IDictionary]) { $item['objectId'] } else { $item.objectId }
        if ($null -eq $objectId) { continue }

        $timestamp = if ($item -is [System.Collections.IDictionary]) {
            if ($item.ContainsKey('_ts')) { $item['_ts'] } else { $item['lastModified'] }
        } else {
            if ($item._ts) { $item._ts } else { $item.lastModified }
        }

        if (-not $unique.ContainsKey($objectId) -or $timestamp -gt $unique[$objectId].Timestamp) {
            $unique[$objectId] = @{ Item = $item; Timestamp = $timestamp }
        }
    }
    return $unique.Values | ForEach-Object { $_.Item }
}

# Helper: Build HTML table
function New-TableHtml {
    param($data, $tableId, $dataType = "")

    if ($data.Count -eq 0) { return @{ Headers = ""; Rows = ""; Props = @() } }

    $props = Get-DynamicProperties -dataArray $data -dataType $dataType

    # Build headers with click handlers
    $headers = (0..($props.Count - 1) | ForEach-Object {
        "<th onclick=`"sortTable($_, '$tableId')`">$($props[$_])</th>"
    }) -join ''

    # Build rows
    $rows = ($data | ForEach-Object {
        $item = $_
        $cells = ($props | ForEach-Object {
            $value = if ($item -is [System.Collections.IDictionary]) { $item[$_] } else { $item.$_ }
            $displayValue = if ($_ -eq 'delta') { Format-Delta $value } else { Format-DisplayValue $value $_ }
            "<td>$displayValue</td>"
        }) -join ''
        "<tr>$cells</tr>"
    }) -join "`n"

    return @{ Headers = $headers; Rows = $rows; Props = $props }
}

try {
    # De-duplicate raw data for all entity types
    $userData = Remove-Duplicates ($usersRawIn ?? @())
    $groupData = Remove-Duplicates ($groupsRawIn ?? @())
    $spData = Remove-Duplicates ($servicePrincipalsRawIn ?? @())
    $riskyUserData = Remove-Duplicates ($riskyUsersRawIn ?? @())
    $deviceData = Remove-Duplicates ($devicesRawIn ?? @())
    $caPolicyData = Remove-Duplicates ($caPoliciesRawIn ?? @())
    $appRegData = Remove-Duplicates ($appRegsRawIn ?? @())
    $authMethodData = Remove-Duplicates ($authMethodsRawIn ?? @())
    $directoryRoleData = Remove-Duplicates ($directoryRolesRawIn ?? @())

    # PIM data
    $pimRoleData = Remove-Duplicates ($pimRolesRawIn ?? @())
    $pimGroupData = Remove-Duplicates ($pimGroupsRawIn ?? @())
    $rolePolicyData = Remove-Duplicates ($rolePoliciesRawIn ?? @())
    $azureRbacData = Remove-Duplicates ($azureRbacRawIn ?? @())

    # Event data (no dedup needed - already unique by ID)
    $signInLogData = $signInLogsIn ?? @()
    $directoryAuditData = $directoryAuditsIn ?? @()

    Write-Verbose "Processed counts - Users: $($userData.Count), Groups: $($groupData.Count), SPs: $($spData.Count)"

    # Combine all changes with category labels
    $allChanges = @()
    @(
        @{ Data = $userChangesIn; Category = 'User' }
        @{ Data = $groupChangesIn; Category = 'Group' }
        @{ Data = $servicePrincipalChangesIn; Category = 'ServicePrincipal' }
        @{ Data = $riskyUserChangesIn; Category = 'RiskyUser' }
        @{ Data = $deviceChangesIn; Category = 'Device' }
        @{ Data = $caPolicyChangesIn; Category = 'CAPolicy' }
        @{ Data = $appRegChangesIn; Category = 'AppRegistration' }
        @{ Data = $authMethodChangesIn; Category = 'AuthMethod' }
        @{ Data = $directoryRoleChangesIn; Category = 'DirectoryRole' }
        @{ Data = $pimRoleChangesIn; Category = 'PimRole' }
        @{ Data = $pimGroupChangesIn; Category = 'PimGroup' }
        @{ Data = $rolePolicyChangesIn; Category = 'RolePolicy' }
        @{ Data = $azureRbacChangesIn; Category = 'AzureRbac' }
    ) | ForEach-Object {
        $category = $_.Category
        if ($_.Data) {
            $_.Data | ForEach-Object {
                if ($_ -is [System.Collections.IDictionary]) { $_['Category'] = $category }
                else { $_ | Add-Member -NotePropertyName "Category" -NotePropertyValue $category -Force }
                $allChanges += $_
            }
        }
    }
    $allChanges = $allChanges | Sort-Object changeTimestamp -Descending | Select-Object -First 200

    # Generate tables for all data types
    $userTable = New-TableHtml -data $userData -tableId 'u-table'
    $groupTable = New-TableHtml -data $groupData -tableId 'g-table'
    $spTable = New-TableHtml -data $spData -tableId 'sp-table'
    $riskyUserTable = New-TableHtml -data $riskyUserData -tableId 'ru-table' -dataType 'risky'
    $deviceTable = New-TableHtml -data $deviceData -tableId 'd-table' -dataType 'device'
    $caPolicyTable = New-TableHtml -data $caPolicyData -tableId 'ca-table' -dataType 'policy'
    $appRegTable = New-TableHtml -data $appRegData -tableId 'ar-table' -dataType 'app'
    $authMethodTable = New-TableHtml -data $authMethodData -tableId 'am-table' -dataType 'auth'
    $directoryRoleTable = New-TableHtml -data $directoryRoleData -tableId 'dr-table' -dataType 'role'
    $signInLogTable = New-TableHtml -data $signInLogData -tableId 'si-table' -dataType 'signin'
    $directoryAuditTable = New-TableHtml -data $directoryAuditData -tableId 'da-table' -dataType 'audit'
    $pimRoleTable = New-TableHtml -data $pimRoleData -tableId 'pr-table' -dataType 'pimrole'
    $pimGroupTable = New-TableHtml -data $pimGroupData -tableId 'pg-table' -dataType 'pimgroup'
    $rolePolicyTable = New-TableHtml -data $rolePolicyData -tableId 'rp-table' -dataType 'rolepolicy'
    $azureRbacTable = New-TableHtml -data $azureRbacData -tableId 'rb-table' -dataType 'rbac'
    $changeTable = New-TableHtml -data $allChanges -tableId 'c-table' -dataType 'changes'

    # Debug info
    $debugInfo = @"
        <div style='background:#e8f4fd;padding:10px;margin:10px 0;border-left:4px solid #0078d4;border-radius:5px;font-size:0.85em;'>
            <b>Data Summary:</b>
            Users: <b>$($userData.Count)</b> |
            Groups: <b>$($groupData.Count)</b> |
            SPs: <b>$($spData.Count)</b> |
            Risky Users: <b>$($riskyUserData.Count)</b> |
            Devices: <b>$($deviceData.Count)</b> |
            CA Policies: <b>$($caPolicyData.Count)</b> |
            App Regs: <b>$($appRegData.Count)</b> |
            Auth Methods: <b>$($authMethodData.Count)</b> |
            Roles: <b>$($directoryRoleData.Count)</b> |
            PIM Roles: <b>$($pimRoleData.Count)</b> |
            PIM Groups: <b>$($pimGroupData.Count)</b> |
            Role Policies: <b>$($rolePolicyData.Count)</b> |
            Azure RBAC: <b>$($azureRbacData.Count)</b> |
            Sign-Ins: <b>$($signInLogData.Count)</b> |
            Audits: <b>$($directoryAuditData.Count)</b> |
            Changes: <b>$($allChanges.Count)</b> |
            Generated: <b>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</b>
        </div>
"@

    $html = @"
<html>
<head>
    <title>Entra Risk Dashboard</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; padding: 20px; background: #f4f4f9; margin: 0; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin-bottom: 20px; }
        .table-container { overflow-x: auto; max-width: 100%; max-height: 70vh; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; background: white; white-space: nowrap; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; cursor: pointer; position: sticky; top: 0; z-index: 1; }
        th:hover { background: #005a9e; }
        td { padding: 10px; border-bottom: 1px solid #eee; font-size: 0.9em; }
        tr:hover { background: #f5f5f5; }
        .tabs { border-bottom: 2px solid #0078d4; margin-bottom: 15px; display: flex; flex-wrap: wrap; gap: 5px; }
        .tab { padding: 8px 15px; border: none; background: none; cursor: pointer; font-weight: bold; color: #666; font-size: 0.9em; }
        .tab.active { color: #0078d4; border-bottom: 3px solid #0078d4; }
        .tab:hover { color: #0078d4; }
        .tab-content { display: none; } .tab-content.active { display: block; }
        .delta-old { color: #d13438; text-decoration: line-through; } .delta-new { color: #107c10; }
        .delta-item { margin: 2px 0; padding: 3px; background: #f9f9f9; border-radius: 3px; }
        .no-data { color: #999; font-style: italic; }
        .section-header { color: #0078d4; margin-top: 20px; padding-bottom: 5px; border-bottom: 1px solid #ddd; }
        .tab-group { display: flex; flex-wrap: wrap; gap: 5px; padding: 5px 0; }
        .tab-divider { border-left: 2px solid #ddd; margin: 0 10px; height: 30px; }
    </style>
    <script>
        function showTab(id, btn) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
            document.getElementById(id).classList.add('active'); btn.classList.add('active');
        }
        function sortTable(n, tableId) {
            var table = document.getElementById(tableId), rows, switching = true, dir = "asc", switchcount = 0;
            while (switching) {
                switching = false; rows = table.rows;
                for (var i = 1; i < rows.length - 1; i++) {
                    var x = rows[i].getElementsByTagName("TD")[n], y = rows[i + 1].getElementsByTagName("TD")[n];
                    if ((dir == "asc" && x.innerHTML.toLowerCase() > y.innerHTML.toLowerCase()) ||
                        (dir == "desc" && x.innerHTML.toLowerCase() < y.innerHTML.toLowerCase())) {
                        rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                        switching = true; switchcount++; break;
                    }
                }
                if (switchcount == 0 && dir == "asc") { dir = "desc"; switching = true; }
            }
        }
    </script>
</head>
<body>
    <h2>Entra Risk Dashboard</h2>
    $debugInfo
    <div class="card">
        <div class="tabs">
            <!-- Core Identity -->
            <button class="tab active" onclick="showTab('u-tab', this)">Users ($($userData.Count))</button>
            <button class="tab" onclick="showTab('g-tab', this)">Groups ($($groupData.Count))</button>
            <button class="tab" onclick="showTab('sp-tab', this)">Service Principals ($($spData.Count))</button>
            <span class="tab-divider"></span>
            <!-- Security -->
            <button class="tab" onclick="showTab('ru-tab', this)">Risky Users ($($riskyUserData.Count))</button>
            <button class="tab" onclick="showTab('ca-tab', this)">CA Policies ($($caPolicyData.Count))</button>
            <button class="tab" onclick="showTab('am-tab', this)">Auth Methods ($($authMethodData.Count))</button>
            <span class="tab-divider"></span>
            <!-- Infrastructure -->
            <button class="tab" onclick="showTab('d-tab', this)">Devices ($($deviceData.Count))</button>
            <button class="tab" onclick="showTab('ar-tab', this)">App Registrations ($($appRegData.Count))</button>
            <button class="tab" onclick="showTab('dr-tab', this)">Directory Roles ($($directoryRoleData.Count))</button>
            <span class="tab-divider"></span>
            <!-- PIM & RBAC -->
            <button class="tab" onclick="showTab('pr-tab', this)">PIM Roles ($($pimRoleData.Count))</button>
            <button class="tab" onclick="showTab('pg-tab', this)">PIM Groups ($($pimGroupData.Count))</button>
            <button class="tab" onclick="showTab('rp-tab', this)">Role Policies ($($rolePolicyData.Count))</button>
            <button class="tab" onclick="showTab('rb-tab', this)">Azure RBAC ($($azureRbacData.Count))</button>
            <span class="tab-divider"></span>
            <!-- Events -->
            <button class="tab" onclick="showTab('si-tab', this)">Sign-In Logs ($($signInLogData.Count))</button>
            <button class="tab" onclick="showTab('da-tab', this)">Audit Logs ($($directoryAuditData.Count))</button>
            <button class="tab" onclick="showTab('c-tab', this)">Changes ($($allChanges.Count))</button>
        </div>

        <!-- Users Tab -->
        <div id="u-tab" class="tab-content active">
            <div class="table-container"><table id="u-table"><thead><tr>$($userTable.Headers)</tr></thead><tbody>$($userTable.Rows)</tbody></table></div>
        </div>

        <!-- Groups Tab -->
        <div id="g-tab" class="tab-content">
            <div class="table-container"><table id="g-table"><thead><tr>$($groupTable.Headers)</tr></thead><tbody>$($groupTable.Rows)</tbody></table></div>
        </div>

        <!-- Service Principals Tab -->
        <div id="sp-tab" class="tab-content">
            <div class="table-container"><table id="sp-table"><thead><tr>$($spTable.Headers)</tr></thead><tbody>$($spTable.Rows)</tbody></table></div>
        </div>

        <!-- Risky Users Tab -->
        <div id="ru-tab" class="tab-content">
            <div class="table-container"><table id="ru-table"><thead><tr>$($riskyUserTable.Headers)</tr></thead><tbody>$($riskyUserTable.Rows)</tbody></table></div>
        </div>

        <!-- CA Policies Tab -->
        <div id="ca-tab" class="tab-content">
            <div class="table-container"><table id="ca-table"><thead><tr>$($caPolicyTable.Headers)</tr></thead><tbody>$($caPolicyTable.Rows)</tbody></table></div>
        </div>

        <!-- Auth Methods Tab -->
        <div id="am-tab" class="tab-content">
            <div class="table-container"><table id="am-table"><thead><tr>$($authMethodTable.Headers)</tr></thead><tbody>$($authMethodTable.Rows)</tbody></table></div>
        </div>

        <!-- Devices Tab -->
        <div id="d-tab" class="tab-content">
            <div class="table-container"><table id="d-table"><thead><tr>$($deviceTable.Headers)</tr></thead><tbody>$($deviceTable.Rows)</tbody></table></div>
        </div>

        <!-- App Registrations Tab -->
        <div id="ar-tab" class="tab-content">
            <div class="table-container"><table id="ar-table"><thead><tr>$($appRegTable.Headers)</tr></thead><tbody>$($appRegTable.Rows)</tbody></table></div>
        </div>

        <!-- Directory Roles Tab -->
        <div id="dr-tab" class="tab-content">
            <div class="table-container"><table id="dr-table"><thead><tr>$($directoryRoleTable.Headers)</tr></thead><tbody>$($directoryRoleTable.Rows)</tbody></table></div>
        </div>

        <!-- PIM Roles Tab -->
        <div id="pr-tab" class="tab-content">
            <div class="table-container"><table id="pr-table"><thead><tr>$($pimRoleTable.Headers)</tr></thead><tbody>$($pimRoleTable.Rows)</tbody></table></div>
        </div>

        <!-- PIM Groups Tab -->
        <div id="pg-tab" class="tab-content">
            <div class="table-container"><table id="pg-table"><thead><tr>$($pimGroupTable.Headers)</tr></thead><tbody>$($pimGroupTable.Rows)</tbody></table></div>
        </div>

        <!-- Role Policies Tab -->
        <div id="rp-tab" class="tab-content">
            <div class="table-container"><table id="rp-table"><thead><tr>$($rolePolicyTable.Headers)</tr></thead><tbody>$($rolePolicyTable.Rows)</tbody></table></div>
        </div>

        <!-- Azure RBAC Tab -->
        <div id="rb-tab" class="tab-content">
            <div class="table-container"><table id="rb-table"><thead><tr>$($azureRbacTable.Headers)</tr></thead><tbody>$($azureRbacTable.Rows)</tbody></table></div>
        </div>

        <!-- Sign-In Logs Tab -->
        <div id="si-tab" class="tab-content">
            <div class="table-container"><table id="si-table"><thead><tr>$($signInLogTable.Headers)</tr></thead><tbody>$($signInLogTable.Rows)</tbody></table></div>
        </div>

        <!-- Directory Audits Tab -->
        <div id="da-tab" class="tab-content">
            <div class="table-container"><table id="da-table"><thead><tr>$($directoryAuditTable.Headers)</tr></thead><tbody>$($directoryAuditTable.Rows)</tbody></table></div>
        </div>

        <!-- Changes Tab -->
        <div id="c-tab" class="tab-content">
            <div class="table-container"><table id="c-table"><thead><tr>$($changeTable.Headers)</tr></thead><tbody>$($changeTable.Rows)</tbody></table></div>
        </div>
    </div>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $html; Headers = @{"content-type"="text/html"} })
} catch {
    Write-Error "Dashboard error: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "Error: $($_.Exception.Message)" })
}
