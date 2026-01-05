using namespace System.Net

param($Request, $TriggerMetadata, $usersRawIn, $groupsRawIn, $servicePrincipalsRawIn, $userChangesIn, $groupChangesIn, $servicePrincipalChangesIn)

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
        @('Category', 'objectId', 'displayName') 
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
    if ($value -is [array]) { return ($value.Count -eq 0) ? "[]" : ("[" + ($value -join ", ") + "]") }
    
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
    
    return [System.Web.HttpUtility]::HtmlEncode($value)
}

# Helper: Render delta changes
function Format-Delta {
    param($delta)
    if ($null -eq $delta -or $delta.PSObject.Properties.Count -eq 0) { return "---" }
    ($delta.PSObject.Properties | ForEach-Object {
        $old = if ($null -eq $_.Value.old) { "null" } else { $_.Value.old }
        $new = if ($null -eq $_.Value.new) { "null" } else { $_.Value.new }
        "<div class='delta-item'><b>$($_.Name)</b>: <span class='delta-old'>$old</span> → <span class='delta-new'>$new</span></div>"
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
    # De-duplicate raw data
    $userData = Remove-Duplicates ($usersRawIn ?? @())
    $groupData = Remove-Duplicates ($groupsRawIn ?? @())
    $spData = Remove-Duplicates ($servicePrincipalsRawIn ?? @())
    
    Write-Verbose "Processed counts - Users: $($userData.Count), Groups: $($groupData.Count), SPs: $($spData.Count)"
    
    # Combine changes with category labels
    $allChanges = @()
    @(
        @{ Data = $userChangesIn; Category = 'User' }
        @{ Data = $groupChangesIn; Category = 'Group' }
        @{ Data = $servicePrincipalChangesIn; Category = 'ServicePrincipal' }
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
    $allChanges = $allChanges | Sort-Object changeTimestamp -Descending
    
    # Generate tables
    $userTable = New-TableHtml -data $userData -tableId 'u-table'
    $groupTable = New-TableHtml -data $groupData -tableId 'g-table'
    $spTable = New-TableHtml -data $spData -tableId 'sp-table'
    $changeTable = New-TableHtml -data $allChanges -tableId 'c-table' -dataType 'changes'
    
    # Debug info
    $debugInfo = @"
        <div style='background:#e8f4fd;padding:10px;margin:10px 0;border-left:4px solid #0078d4;border-radius:5px;font-size:0.9em;'>
            <b>Data Summary:</b>
            Users: <b>$($userData.Count)</b> records ($($userTable.Props.Count) properties) |
            Groups: <b>$($groupData.Count)</b> records ($($groupTable.Props.Count) properties) |
            Service Principals: <b>$($spData.Count)</b> records ($($spTable.Props.Count) properties) |
            Changes: <b>$($allChanges.Count)</b> records ($($changeTable.Props.Count) properties) |
            Generated: <b>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</b>
        </div>
"@

    $html = @"
<html>
<head>
    <style>
        body { font-family: 'Segoe UI', sans-serif; padding: 20px; background: #f4f4f9; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin-bottom: 20px; }
        .table-container { overflow-x: auto; max-width: 100%; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; background: white; white-space: nowrap; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; cursor: pointer; position: sticky; top: 0; }
        th:hover { background: #005a9e; }
        td { padding: 10px; border-bottom: 1px solid #eee; font-size: 0.9em; }
        .tabs { border-bottom: 2px solid #0078d4; margin-bottom: 15px; }
        .tab { padding: 10px 20px; border: none; background: none; cursor: pointer; font-weight: bold; color: #666; }
        .tab.active { color: #0078d4; border-bottom: 3px solid #0078d4; }
        .tab-content { display: none; } .tab-content.active { display: block; }
        .delta-old { color: #d13438; text-decoration: line-through; } .delta-new { color: #107c10; }
        .delta-item { margin: 2px 0; padding: 3px; background: #f9f9f9; border-radius: 3px; }
        .no-data { color: #999; font-style: italic; }
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
            <button class="tab active" onclick="showTab('u-tab', this)">Users ($($userData.Count))</button>
            <button class="tab" onclick="showTab('g-tab', this)">Groups ($($groupData.Count))</button>
            <button class="tab" onclick="showTab('sp-tab', this)">Service Principals ($($spData.Count))</button>
            <button class="tab" onclick="showTab('c-tab', this)">Recent Changes ($($allChanges.Count))</button>
        </div>
        <div id="u-tab" class="tab-content active">
            <div class="table-container"><table id="u-table"><thead><tr>$($userTable.Headers)</tr></thead><tbody>$($userTable.Rows)</tbody></table></div>
        </div>
        <div id="g-tab" class="tab-content">
            <div class="table-container"><table id="g-table"><thead><tr>$($groupTable.Headers)</tr></thead><tbody>$($groupTable.Rows)</tbody></table></div>
        </div>
        <div id="sp-tab" class="tab-content">
            <div class="table-container"><table id="sp-table"><thead><tr>$($spTable.Headers)</tr></thead><tbody>$($spTable.Rows)</tbody></table></div>
        </div>
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