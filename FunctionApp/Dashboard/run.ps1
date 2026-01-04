using namespace System.Net

param($Request, $TriggerMetadata, $usersRawIn, $groupsRawIn, $userChangesIn, $groupChangesIn)

Add-Type -AssemblyName System.Web
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

# Helper to render delta changes
$renderDelta = {
    param($delta)
    if ($null -eq $delta -or $delta.PSObject.Properties.Count -eq 0) { return "---" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($prop in $delta.PSObject.Properties) {
        $oldVal = if ($null -eq $prop.Value.old) { "null" } else { $prop.Value.old }
        $newVal = if ($null -eq $prop.Value.new) { "null" } else { $prop.Value.new }
        [void]$sb.AppendLine("<div class='delta-item'><b>$($prop.Name)</b>: <span class='delta-old'>$oldVal</span> → <span class='delta-new'>$newVal</span></div>")
    }
    return $sb.ToString()
}

$formatDate = {
    param($dateString)
    if ($dateString) { try { return ([DateTime]::Parse($dateString)).ToString("yyyy-MM-dd HH:mm") } catch { return $dateString } }
    return "<span class='no-data'>Never</span>"
}

try {
    $userDataArray = if ($usersRawIn) { $usersRawIn } else { @() }
    $groupDataArray = if ($groupsRawIn) { $groupsRawIn } else { @() }

    # Build User Rows
    $userRows = New-Object System.Text.StringBuilder
    foreach ($u in $userDataArray) {
        $status = if ($u.accountEnabled -eq $true) { "Enabled" } else { "Disabled" }
        [void]$userRows.AppendLine("<tr><td>$($u.objectId)</td><td>$([System.Web.HttpUtility]::HtmlEncode($u.displayName))</td><td>$($u.userPrincipalName)</td><td>$status</td><td>$($u.userType)</td><td>$(& $formatDate $u.lastSignInDateTime)</td></tr>")
    }

    # Build Group Rows
    $groupRows = New-Object System.Text.StringBuilder
    foreach ($g in $groupDataArray) {
        [void]$groupRows.AppendLine("<tr><td>$($g.objectId)</td><td>$([System.Web.HttpUtility]::HtmlEncode($g.displayName))</td><td>$($g.mailEnabled)</td><td>$([System.Web.HttpUtility]::HtmlEncode($g.description))</td><td>$(& $formatDate $g.createdDateTime)</td></tr>")
    }

    # Build Change Rows (Combined Users and Groups)
    $changeRows = New-Object System.Text.StringBuilder
    $allChanges = @()
    if ($userChangesIn) { $userChangesIn | ForEach-Object { $_ | Add-Member -NotePropertyName "Category" -NotePropertyValue "User"; $allChanges += $_ } }
    if ($groupChangesIn) { $groupChangesIn | ForEach-Object { $_ | Add-Member -NotePropertyName "Category" -NotePropertyValue "Group"; $allChanges += $_ } }

    foreach ($c in ($allChanges | Sort-Object changeTimestamp -Descending)) {
        [void]$changeRows.AppendLine("<tr><td>$($c.Category)</td><td>$($c.newValue.displayName)</td><td>$($c.changeType)</td><td>$(& $renderDelta $c.delta)</td><td>$(& $formatDate $c.changeTimestamp)</td></tr>")
    }

    $html = @"
<html>
<head>
    <style>
        body { font-family: 'Segoe UI', sans-serif; padding: 20px; background: #f4f4f9; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; background: white; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; cursor: pointer; position: sticky; top: 0; }
        th:hover { background: #005a9e; }
        td { padding: 10px; border-bottom: 1px solid #eee; font-size: 0.9em; }
        .tabs { border-bottom: 2px solid #0078d4; margin-bottom: 15px; }
        .tab { padding: 10px 20px; border: none; background: none; cursor: pointer; font-weight: bold; color: #666; }
        .tab.active { color: #0078d4; border-bottom: 3px solid #0078d4; }
        .tab-content { display: none; } .tab-content.active { display: block; }
        .delta-old { color: #d13438; text-decoration: line-through; } .delta-new { color: #107c10; }
    </style>
    <script>
        function showTab(id, btn) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
            document.getElementById(id).classList.add('active'); btn.classList.add('active');
        }
        function sortTable(n, tableId) {
            var table = document.getElementById(tableId);
            var rows, switching, i, x, y, shouldSwitch, dir, switchcount = 0;
            switching = true; dir = "asc";
            while (switching) {
                switching = false; rows = table.rows;
                for (i = 1; i < (rows.length - 1); i++) {
                    shouldSwitch = false;
                    x = rows[i].getElementsByTagName("TD")[n];
                    y = rows[i + 1].getElementsByTagName("TD")[n];
                    if (dir == "asc") {
                        if (x.innerHTML.toLowerCase() > y.innerHTML.toLowerCase()) { shouldSwitch = true; break; }
                    } else if (dir == "desc") {
                        if (x.innerHTML.toLowerCase() < y.innerHTML.toLowerCase()) { shouldSwitch = true; break; }
                    }
                }
                if (shouldSwitch) {
                    rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                    switching = true; switchcount ++;
                } else {
                    if (switchcount == 0 && dir == "asc") { dir = "desc"; switching = true; }
                }
            }
        }
    </script>
</head>
<body>
    <h2>Entra Risk Dashboard</h2>
    <div class="card">
        <div class="tabs">
            <button class="tab active" onclick="showTab('u-tab', this)">Users ($($userDataArray.Count))</button>
            <button class="tab" onclick="showTab('g-tab', this)">Groups ($($groupDataArray.Count))</button>
            <button class="tab" onclick="showTab('c-tab', this)">Recent Changes</button>
        </div>

        <div id="u-tab" class="tab-content active">
            <table id="u-table">
                <thead><tr><th onclick="sortTable(0, 'u-table')">ID</th><th onclick="sortTable(1, 'u-table')">Name</th><th onclick="sortTable(2, 'u-table')">UPN</th><th onclick="sortTable(3, 'u-table')">Status</th><th onclick="sortTable(4, 'u-table')">Type</th><th onclick="sortTable(5, 'u-table')">Last Sign-In</th></tr></thead>
                <tbody>$($userRows.ToString())</tbody>
            </table>
        </div>

        <div id="g-tab" class="tab-content">
            <table id="g-table">
                <thead><tr><th onclick="sortTable(0, 'g-table')">ID</th><th onclick="sortTable(1, 'g-table')">Name</th><th onclick="sortTable(2, 'g-table')">Mail</th><th onclick="sortTable(3, 'g-table')">Description</th><th onclick="sortTable(4, 'g-table')">Created</th></tr></thead>
                <tbody>$($groupRows.ToString())</tbody>
            </table>
        </div>

        <div id="c-tab" class="tab-content">
            <table id="c-table">
                <thead><tr><th onclick="sortTable(0, 'c-table')">Category</th><th onclick="sortTable(1, 'c-table')">Name</th><th onclick="sortTable(2, 'c-table')">Action</th><th onclick="sortTable(3, 'c-table')">Changes</th><th onclick="sortTable(4, 'c-table')">Time</th></tr></thead>
                <tbody>$($changeRows.ToString())</tbody>
            </table>
        </div>
    </div>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $html; headers = @{"content-type"="text/html"} })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "Error: $($_.Exception.Message)" })
}