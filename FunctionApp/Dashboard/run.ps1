using namespace System.Net

param($Request, $TriggerMetadata, $usersRawIn, $groupsRawIn, $userChangesIn, $groupChangesIn)

Add-Type -AssemblyName System.Web
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

# Helper to get all unique properties from an array, with objectId and displayName first
$getDynamicProperties = {
    param($dataArray, [string]$dataType = "")
    
    if ($null -eq $dataArray -or $dataArray.Count -eq 0) { return @() }
    
    # Collect all unique property names from all objects
    $allPropsHash = @{}
    
    foreach ($item in $dataArray) {
        # Handle both PSCustomObject and Hashtable
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in $item.Keys) {
                $allPropsHash[$key] = $true
            }
        }
        else {
            # Get all properties from the object
            $item.PSObject.Properties | ForEach-Object {
                $allPropsHash[$_.Name] = $true
            }
        }
    }
    
    # Convert to sorted array, excluding Cosmos DB internal properties
    $allProps = $allPropsHash.Keys | Where-Object { 
        $_ -notmatch '^_' # Exclude _rid, _self, _etag, _attachments, _ts
    } | Sort-Object
    
    # Build ordered properties based on data type
    $orderedProps = @()
    
    if ($dataType -eq "changes") {
        # For changes: Category first, then objectId, displayName, then rest
        if ($allProps -contains 'Category') { $orderedProps += 'Category' }
        if ($allProps -contains 'objectId') { $orderedProps += 'objectId' }
        if ($allProps -contains 'displayName') { $orderedProps += 'displayName' }
        
        foreach ($p in $allProps) {
            if ($p -notin @('Category', 'objectId', 'displayName')) {
                $orderedProps += $p
            }
        }
    }
    else {
        # For users/groups: objectId first, then displayName, then rest
        if ($allProps -contains 'objectId') { $orderedProps += 'objectId' }
        if ($allProps -contains 'displayName') { $orderedProps += 'displayName' }
        
        foreach ($p in $allProps) {
            if ($p -ne 'objectId' -and $p -ne 'displayName') {
                $orderedProps += $p
            }
        }
    }
    
    return $orderedProps
}

# Helper to format a value for display
$formatValue = {
    param($value, $propertyName)
    
    if ($null -eq $value) {
        return "<span class='no-data'>null</span>"
    }
    elseif ($value -is [bool]) {
        return $value.ToString()
    }
    elseif ($value -is [array]) {
        if ($value.Count -eq 0) { return "[]" }
        return "[" + ($value -join ", ") + "]"
    }
    elseif ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject]) {
        # Handle hashtables and PSCustomObjects (like newValue, previousValue)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<div style='font-size:0.85em;'>")
        
        # Get properties
        $props = if ($value -is [System.Collections.IDictionary]) {
            $value.Keys
        } else {
            $value.PSObject.Properties.Name
        }
        
        # Display key properties in compact format
        $displayedCount = 0
        $maxDisplay = 5
        foreach ($p in $props) {
            if ($displayedCount -ge $maxDisplay) { 
                [void]$sb.Append("<div style='color:#666;font-style:italic;'>... +$($props.Count - $maxDisplay) more</div>")
                break 
            }
            
            $pValue = if ($value -is [System.Collections.IDictionary]) { $value[$p] } else { $value.$p }
            $displayValue = if ($null -eq $pValue) { "null" } else { [System.Web.HttpUtility]::HtmlEncode($pValue.ToString()) }
            
            [void]$sb.Append("<div><b>$p </b> $displayValue</div>")
            $displayedCount++
        }
        [void]$sb.Append("</div>")
        return $sb.ToString()
    }
    elseif ($propertyName -match 'DateTime' -or $propertyName -match 'Timestamp') {
        try {
            return ([DateTime]::Parse($value)).ToString("yyyy-MM-dd HH:mm")
        } catch {
            return [System.Web.HttpUtility]::HtmlEncode($value)
        }
    }
    else {
        return [System.Web.HttpUtility]::HtmlEncode($value)
    }
}

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

try {
    $userDataArray = if ($usersRawIn) { $usersRawIn } else { @() }
    $groupDataArray = if ($groupsRawIn) { $groupsRawIn } else { @() }

    # DEBUG: Log what we're receiving
    Write-Verbose "User data count: $($userDataArray.Count)"
    Write-Verbose "Group data count: $($groupDataArray.Count)"
    
    if ($userDataArray.Count -gt 0) {
        Write-Verbose "First user object type: $($userDataArray[0].GetType().FullName)"
        Write-Verbose "First user properties: $($userDataArray[0].PSObject.Properties.Name -join ', ')"
    }

    # Get dynamic properties for users
    $userProps = & $getDynamicProperties $userDataArray
    Write-Verbose "Detected user properties: $($userProps -join ', ')"
    
    # Build User Headers
    $userHeaders = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $userProps.Count; $i++) {
        [void]$userHeaders.Append("<th onclick=`"sortTable($i, 'u-table')`">$($userProps[$i])</th>")
    }

    # Build User Rows
    $userRows = New-Object System.Text.StringBuilder
    foreach ($u in $userDataArray) {
        [void]$userRows.Append("<tr>")
        foreach ($prop in $userProps) {
            $value = $u.$prop
            $displayValue = & $formatValue $value $prop
            [void]$userRows.Append("<td>$displayValue</td>")
        }
        [void]$userRows.AppendLine("</tr>")
    }

    # Get dynamic properties for groups
    $groupProps = & $getDynamicProperties $groupDataArray
    Write-Verbose "Detected group properties: $($groupProps -join ', ')"
    
    # Build Group Headers
    $groupHeaders = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $groupProps.Count; $i++) {
        [void]$groupHeaders.Append("<th onclick=`"sortTable($i, 'g-table')`">$($groupProps[$i])</th>")
    }

    # Build Group Rows
    $groupRows = New-Object System.Text.StringBuilder
    foreach ($g in $groupDataArray) {
        [void]$groupRows.Append("<tr>")
        foreach ($prop in $groupProps) {
            $value = $g.$prop
            $displayValue = & $formatValue $value $prop
            [void]$groupRows.Append("<td>$displayValue</td>")
        }
        [void]$groupRows.AppendLine("</tr>")
    }

    # Build Change Rows (Combined Users and Groups) - NOW DYNAMIC
    $changeRows = New-Object System.Text.StringBuilder
    $allChanges = @()

    # Add Category property to identify User vs Group changes
    # Handle both hashtables (from Cosmos DB) and PSCustomObjects
    if ($userChangesIn) {
        $userChangesIn | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                $_['Category'] = 'User'
            } else {
                $_ | Add-Member -NotePropertyName "Category" -NotePropertyValue "User" -Force
            }
            $allChanges += $_
        }
    }
    if ($groupChangesIn) {
        $groupChangesIn | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                $_['Category'] = 'Group'
            } else {
                $_ | Add-Member -NotePropertyName "Category" -NotePropertyValue "Group" -Force
            }
            $allChanges += $_
        }
    }

    # Get dynamic properties for changes
    $changeProps = & $getDynamicProperties $allChanges "changes"
    
    # ENSURE Category is always first if we have changes
    if ($allChanges.Count -gt 0 -and $changeProps -notcontains 'Category') {
        $changeProps = @('Category') + $changeProps
    }
    
    Write-Verbose "Change properties detected: $($changeProps -join ', ')"
    
    # Build Change Headers
    $changeHeaders = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $changeProps.Count; $i++) {
        [void]$changeHeaders.Append("<th onclick=`"sortTable($i, 'c-table')`">$($changeProps[$i])</th>")
    }

    # Build Change Rows with all properties
    foreach ($c in ($allChanges | Sort-Object changeTimestamp -Descending)) {
        [void]$changeRows.Append("<tr>")
        foreach ($prop in $changeProps) {
            # Get the value - handle both hashtable and object notation
            $value = if ($c -is [System.Collections.IDictionary]) { 
                $c[$prop] 
            } else { 
                $c.$prop 
            }
            
            # Special handling for delta object
            if ($prop -eq 'delta') {
                $displayValue = & $renderDelta $value
            }
            else {
                $displayValue = & $formatValue $value $prop
            }
            
            [void]$changeRows.Append("<td>$displayValue</td>")
        }
        [void]$changeRows.AppendLine("</tr>")
    }
    
    # Simple debug info
    $debugInfo = @"
        <div style='background:#e8f4fd;padding:10px;margin:10px 0;border-left:4px solid #0078d4;border-radius:5px;font-size:0.9em;'>
            <b>Data Summary:</b> 
            Users: <b>$($userDataArray.Count)</b> records ($($userProps.Count) properties) | 
            Groups: <b>$($groupDataArray.Count)</b> records ($($groupProps.Count) properties) | 
            Changes: <b>$($allChanges.Count)</b> records ($($changeProps.Count) properties) | 
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
    $debugInfo
    <div class="card">
        <div class="tabs">
            <button class="tab active" onclick="showTab('u-tab', this)">Users ($($userDataArray.Count))</button>
            <button class="tab" onclick="showTab('g-tab', this)">Groups ($($groupDataArray.Count))</button>
            <button class="tab" onclick="showTab('c-tab', this)">Recent Changes ($($allChanges.Count))</button>
        </div>

        <div id="u-tab" class="tab-content active">
            <div class="table-container">
                <table id="u-table">
                    <thead><tr>$($userHeaders.ToString())</tr></thead>
                    <tbody>$($userRows.ToString())</tbody>
                </table>
            </div>
        </div>

        <div id="g-tab" class="tab-content">
            <div class="table-container">
                <table id="g-table">
                    <thead><tr>$($groupHeaders.ToString())</tr></thead>
                    <tbody>$($groupRows.ToString())</tbody>
                </table>
            </div>
        </div>

        <div id="c-tab" class="tab-content">
            <div class="table-container">
                <table id="c-table">
                    <thead><tr>$($changeHeaders.ToString())</tr></thead>
                    <tbody>$($changeRows.ToString())</tbody>
                </table>
            </div>
        </div>
    </div>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $html; headers = @{"content-type"="text/html"} })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "Error: $($_.Exception.Message)" })
}