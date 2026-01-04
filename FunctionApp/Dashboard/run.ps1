using namespace System.Net

param($Request, $TriggerMetadata, $usersRawIn, $groupsRawIn)

# Load System.Web for HTML encoding
Add-Type -AssemblyName System.Web

# Import the module
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

try {
    #region Fetch User Data
    $userDataArray = @()
    $userRecordCount = 0
    $userDataSource = ""

    # Try to use Cosmos DB data from input binding
    if ($usersRawIn -and $usersRawIn.Count -gt 0) {
        Write-Host "Using Cosmos DB user data from input binding ($($usersRawIn.Count) records)"
        $userDataArray = $usersRawIn
        $userRecordCount = $userDataArray.Count
        $userDataSource = "Cosmos DB (users_raw container)"
    } else {
        # Fallback to Blob Storage for users
        Write-Host "Cosmos DB user binding returned no data, falling back to Blob Storage..."

        $storageAccountName = $env:STORAGE_ACCOUNT_NAME
        $containerName = "raw-data"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

        $storageHeaders = @{
            'Authorization' = "Bearer $storageToken"
            'x-ms-version'   = '2021-08-06'
            'x-ms-date'      = [DateTime]::UtcNow.ToString('r')
        }

        $listUri = "https://{0}.blob.core.windows.net/{1}?restype=container&comp=list" -f $storageAccountName, $containerName
        $listResponse = Invoke-WebRequest -Uri $listUri -Method Get -Headers $storageHeaders

        [xml]$xmlResponse = $listResponse.Content
        $blobs = $xmlResponse.EnumerationResults.Blobs.Blob

        if ($blobs -isnot [array]) {
            $blobs = @($blobs)
        }

        $targetBlob = $blobs |
                      Where-Object { $_.Name -like "*-users.jsonl" } |
                      Sort-Object { [DateTime]$_.Properties.'Last-Modified' } -Descending |
                      Select-Object -First 1

        if ($targetBlob) {
            $blobPath = $targetBlob.Name
            $blobUri = "https://{0}.blob.core.windows.net/{1}/{2}" -f $storageAccountName, $containerName, $blobPath
            $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $storageHeaders

            foreach ($line in ($blobContent -split "`n")) {
                if ($line.Trim()) {
                    try {
                        $userDataArray += $line | ConvertFrom-Json
                    } catch {
                        Write-Host "Failed to parse user line: $line"
                    }
                }
            }

            $userRecordCount = $userDataArray.Count
            $userDataSource = "Blob Storage ($blobPath)"
        } else {
            $userDataSource = "No user data available"
        }
    }
    #endregion

    #region Fetch Group Data
    $groupDataArray = @()
    $groupRecordCount = 0
    $groupDataSource = ""

    # Try to use Cosmos DB data from input binding
    if ($groupsRawIn -and $groupsRawIn.Count -gt 0) {
        Write-Host "Using Cosmos DB group data from input binding ($($groupsRawIn.Count) records)"
        $groupDataArray = $groupsRawIn
        $groupRecordCount = $groupDataArray.Count
        $groupDataSource = "Cosmos DB (groups_raw container)"
    } else {
        # Fallback to Blob Storage for groups
        Write-Host "Cosmos DB group binding returned no data, falling back to Blob Storage..."

        if (-not $storageAccountName) {
            $storageAccountName = $env:STORAGE_ACCOUNT_NAME
            $containerName = "raw-data"
            $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

            $storageHeaders = @{
                'Authorization' = "Bearer $storageToken"
                'x-ms-version'   = '2021-08-06'
                'x-ms-date'      = [DateTime]::UtcNow.ToString('r')
            }
        }

        $listUri = "https://{0}.blob.core.windows.net/{1}?restype=container&comp=list" -f $storageAccountName, $containerName
        $listResponse = Invoke-WebRequest -Uri $listUri -Method Get -Headers $storageHeaders

        [xml]$xmlResponse = $listResponse.Content
        $blobs = $xmlResponse.EnumerationResults.Blobs.Blob

        if ($blobs -isnot [array]) {
            $blobs = @($blobs)
        }

        $targetBlob = $blobs |
                      Where-Object { $_.Name -like "*-groups.jsonl" } |
                      Sort-Object { [DateTime]$_.Properties.'Last-Modified' } -Descending |
                      Select-Object -First 1

        if ($targetBlob) {
            $blobPath = $targetBlob.Name
            $blobUri = "https://{0}.blob.core.windows.net/{1}/{2}" -f $storageAccountName, $containerName, $blobPath
            $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $storageHeaders

            foreach ($line in ($blobContent -split "`n")) {
                if ($line.Trim()) {
                    try {
                        $groupDataArray += $line | ConvertFrom-Json
                    } catch {
                        Write-Host "Failed to parse group line: $line"
                    }
                }
            }

            $groupRecordCount = $groupDataArray.Count
            $groupDataSource = "Blob Storage ($blobPath)"
        } else {
            $groupDataSource = "No group data available"
        }
    }
    #endregion

    #region Build User Table HTML
    $userTableRows = New-Object System.Text.StringBuilder
    $userDisplayCount = [Math]::Min($userDataArray.Count, 100)

    for ($i = 0; $i -lt $userDisplayCount; $i++) {
        $user = $userDataArray[$i]

        # Helper function to format values
        $formatValue = {
            param($value)
            if ($null -eq $value -or $value -eq "") {
                return "<span class='no-data'>N/A</span>"
            }
            return [System.Web.HttpUtility]::HtmlEncode($value)
        }

        # Status badge for accountEnabled
        $statusBadge = if ($user.accountEnabled -eq $true) {
            "<span class='badge badge-enabled'>Enabled</span>"
        } elseif ($user.accountEnabled -eq $false) {
            "<span class='badge badge-disabled'>Disabled</span>"
        } else {
            "<span class='badge badge-unknown'>Unknown</span>"
        }

        # User type badge
        $typeBadge = if ($user.userType -eq 'Member') {
            "<span class='badge badge-member'>Member</span>"
        } elseif ($user.userType -eq 'Guest') {
            "<span class='badge badge-guest'>Guest</span>"
        } else {
            "<span class='badge badge-unknown'>$($user.userType)</span>"
        }

        # Sync status
        $syncStatus = if ($user.onPremisesSyncEnabled -eq $true) {
            "<span class='badge badge-synced'>Synced</span>"
        } else {
            "<span class='badge badge-cloud'>Cloud-only</span>"
        }

        # Format dates
        $formatDate = {
            param($dateString)
            if ($dateString) {
                try {
                    $dt = [DateTime]::Parse($dateString)
                    return $dt.ToString("yyyy-MM-dd HH:mm")
                } catch {
                    return $dateString
                }
            }
            return "<span class='no-data'>Never</span>"
        }

        $createdDate = & $formatDate $user.createdDateTime
        $lastSignIn = & $formatDate $user.lastSignInDateTime
        $collectionTime = & $formatDate $user.collectionTimestamp

        # Format other fields
        $objectId = & $formatValue $user.objectId
        $upn = & $formatValue $user.userPrincipalName
        $displayName = & $formatValue $user.displayName

        [void]$userTableRows.AppendLine(@"
        <tr>
            <td class='id-cell'>$objectId</td>
            <td>$displayName</td>
            <td class='upn'>$upn</td>
            <td class='centered'>$statusBadge</td>
            <td class='centered'>$typeBadge</td>
            <td class='centered'>$syncStatus</td>
            <td>$createdDate</td>
            <td>$lastSignIn</td>
            <td class='small-text'>$collectionTime</td>
        </tr>
"@)
    }
    #endregion

    #region Build Group Table HTML
    $groupTableRows = New-Object System.Text.StringBuilder
    $groupDisplayCount = [Math]::Min($groupDataArray.Count, 100)

    for ($i = 0; $i -lt $groupDisplayCount; $i++) {
        $group = $groupDataArray[$i]

        # Helper function to format values
        $formatValue = {
            param($value)
            if ($null -eq $value -or $value -eq "") {
                return "<span class='no-data'>N/A</span>"
            }
            return [System.Web.HttpUtility]::HtmlEncode($value)
        }

        # Security enabled badge
        $securityBadge = if ($group.securityEnabled -eq $true) {
            "<span class='badge badge-security'>Security</span>"
        } else {
            "<span class='badge badge-disabled'>Not Security</span>"
        }

        # Mail enabled badge
        $mailBadge = if ($group.mailEnabled -eq $true) {
            "<span class='badge badge-mail'>Mail Enabled</span>"
        } else {
            "<span class='badge badge-disabled'>No Mail</span>"
        }

        # Group type badge (M365, Security, Distribution)
        $groupTypeBadge = ""
        if ($group.groupTypes -and $group.groupTypes -contains "Unified") {
            $groupTypeBadge = "<span class='badge badge-m365'>Microsoft 365</span>"
        } elseif ($group.securityEnabled -and -not $group.mailEnabled) {
            $groupTypeBadge = "<span class='badge badge-security'>Security Group</span>"
        } elseif ($group.mailEnabled -and $group.securityEnabled) {
            $groupTypeBadge = "<span class='badge badge-mail-security'>Mail-Enabled Security</span>"
        } elseif ($group.mailEnabled) {
            $groupTypeBadge = "<span class='badge badge-distribution'>Distribution List</span>"
        } else {
            $groupTypeBadge = "<span class='badge badge-unknown'>Unknown</span>"
        }

        # Role assignable badge (PIM-eligible)
        $roleAssignableBadge = if ($group.isAssignableToRole -eq $true) {
            "<span class='badge badge-pim'>PIM Eligible</span>"
        } else {
            "<span class='no-data'>N/A</span>"
        }

        # Sync status
        $syncStatus = if ($group.onPremisesSyncEnabled -eq $true) {
            "<span class='badge badge-synced'>Synced</span>"
        } else {
            "<span class='badge badge-cloud'>Cloud-only</span>"
        }

        # Format dates
        $formatDate = {
            param($dateString)
            if ($dateString) {
                try {
                    $dt = [DateTime]::Parse($dateString)
                    return $dt.ToString("yyyy-MM-dd HH:mm")
                } catch {
                    return $dateString
                }
            }
            return "<span class='no-data'>Never</span>"
        }

        $createdDate = & $formatDate $group.createdDateTime
        $collectionTime = & $formatDate $group.collectionTimestamp

        # Format other fields
        $objectId = & $formatValue $group.objectId
        $displayName = & $formatValue $group.displayName
        $description = & $formatValue $group.description
        $mail = & $formatValue $group.mail
        $membershipRule = & $formatValue $group.membershipRule

        [void]$groupTableRows.AppendLine(@"
        <tr>
            <td class='id-cell'>$objectId</td>
            <td>$displayName</td>
            <td class='centered'>$groupTypeBadge</td>
            <td class='centered'>$securityBadge</td>
            <td class='centered'>$mailBadge</td>
            <td class='centered'>$roleAssignableBadge</td>
            <td class='centered'>$syncStatus</td>
            <td class='description'>$description</td>
            <td class='upn'>$mail</td>
            <td>$createdDate</td>
            <td class='small-text'>$membershipRule</td>
            <td class='small-text'>$collectionTime</td>
        </tr>
"@)
    }
    #endregion

    $html = @"
<html>
<head>
    <title>Entra Risk Dashboard</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            padding: 25px;
            background: #f5f5f5;
            margin: 0;
        }
        h1 { color: #0078d4; margin-bottom: 10px; }
        .card {
            background: #fff;
            padding: 20px;
            border: 1px solid #ddd;
            border-radius: 8px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .stat { display: inline-block; margin-right: 30px; }
        .stat-label { color: #666; font-size: 0.9em; }
        .stat-value { font-size: 1.5em; font-weight: bold; color: #0078d4; }
        .success { color: #107c10; }
        .warning { color: #ff8c00; }

        /* Tab styles */
        .tabs {
            display: flex;
            border-bottom: 2px solid #0078d4;
            margin-bottom: 20px;
        }
        .tab {
            padding: 12px 24px;
            cursor: pointer;
            border: none;
            background: none;
            font-size: 1em;
            font-weight: 600;
            color: #666;
            border-bottom: 3px solid transparent;
            transition: all 0.3s;
        }
        .tab:hover {
            color: #0078d4;
            background: #f0f0f0;
        }
        .tab.active {
            color: #0078d4;
            border-bottom: 3px solid #0078d4;
        }
        .tab-content {
            display: none;
        }
        .tab-content.active {
            display: block;
        }

        /* Table styles */
        .data-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
            font-size: 0.9em;
        }
        .data-table thead {
            background: #0078d4;
            color: white;
        }
        .data-table th {
            padding: 12px 10px;
            text-align: left;
            font-weight: 600;
            border-bottom: 2px solid #005a9e;
        }
        .data-table td {
            padding: 10px;
            border-bottom: 1px solid #e0e0e0;
        }
        .data-table tr:hover {
            background-color: #f8f8f8;
        }
        .data-table tr:last-child td {
            border-bottom: none;
        }

        /* Badge styles */
        .badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: 600;
            white-space: nowrap;
        }
        .badge-enabled {
            background: #d4edda;
            color: #155724;
        }
        .badge-disabled {
            background: #f8d7da;
            color: #721c24;
        }
        .badge-member {
            background: #d1ecf1;
            color: #0c5460;
        }
        .badge-guest {
            background: #fff3cd;
            color: #856404;
        }
        .badge-synced {
            background: #e7e7ff;
            color: #4a4a8a;
        }
        .badge-cloud {
            background: #e0f2ff;
            color: #004578;
        }
        .badge-security {
            background: #d4edda;
            color: #155724;
        }
        .badge-mail {
            background: #cfe2ff;
            color: #084298;
        }
        .badge-mail-security {
            background: #d1ecf1;
            color: #0c5460;
        }
        .badge-distribution {
            background: #fff3cd;
            color: #856404;
        }
        .badge-m365 {
            background: #d6a8ff;
            color: #3d0066;
        }
        .badge-pim {
            background: #ffe5b4;
            color: #cc5500;
            font-weight: 700;
        }
        .badge-unknown {
            background: #e2e3e5;
            color: #383d41;
        }

        /* Utility styles */
        .centered {
            text-align: center;
        }
        .upn {
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: 0.85em;
            color: #333;
        }
        .description {
            max-width: 250px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            font-size: 0.9em;
        }
        .no-data {
            color: #999;
            font-style: italic;
        }
        .id-cell {
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: 0.75em;
            color: #666;
            max-width: 120px;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        .small-text {
            font-size: 0.85em;
            max-width: 150px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        /* Responsive table container */
        .table-container {
            overflow-x: auto;
            max-height: 700px;
            overflow-y: auto;
        }

        .info-note {
            background: #fff3cd;
            border-left: 4px solid #ffc107;
            padding: 10px 15px;
            margin-top: 15px;
            border-radius: 4px;
            font-size: 0.9em;
            color: #856404;
        }
    </style>
    <script>
        function showTab(tabName) {
            // Hide all tab contents
            var contents = document.getElementsByClassName('tab-content');
            for (var i = 0; i < contents.length; i++) {
                contents[i].classList.remove('active');
            }

            // Remove active class from all tabs
            var tabs = document.getElementsByClassName('tab');
            for (var i = 0; i < tabs.length; i++) {
                tabs[i].classList.remove('active');
            }

            // Show selected tab content and mark tab as active
            document.getElementById(tabName).classList.add('active');
            event.target.classList.add('active');
        }
    </script>
</head>
<body>
    <h1>Entra Risk Dashboard</h1>

    <div class="card">
        <h3>Connection Status</h3>
        <p class="success">✓ Successfully connected to Azure resources</p>
    </div>

    <div class="card">
        <h3>Data Summary</h3>
        <div class="stat">
            <div class="stat-label">User Records</div>
            <div class="stat-value">$userRecordCount</div>
        </div>
        <div class="stat">
            <div class="stat-label">Group Records</div>
            <div class="stat-value">$groupRecordCount</div>
        </div>
    </div>

    <div class="card">
        <div class="tabs">
            <button class="tab active" onclick="showTab('users-tab')">Users</button>
            <button class="tab" onclick="showTab('groups-tab')">Groups</button>
        </div>

        <div id="users-tab" class="tab-content active">
            <h3>User Data</h3>
            <p><b>Source:</b> $userDataSource</p>
            <div class="table-container">
                <table class="data-table">
                    <thead>
                        <tr>
                            <th>Object ID</th>
                            <th>Display Name</th>
                            <th>User Principal Name</th>
                            <th style="text-align: center;">Status</th>
                            <th style="text-align: center;">Type</th>
                            <th style="text-align: center;">Sync</th>
                            <th>Created Date</th>
                            <th>Last Sign-In</th>
                            <th>Collection Time</th>
                        </tr>
                    </thead>
                    <tbody>
$($userTableRows.ToString())
                    </tbody>
                </table>
            </div>
            <div class="info-note">
                Showing $userDisplayCount of $userRecordCount user records
            </div>
        </div>

        <div id="groups-tab" class="tab-content">
            <h3>Group Data</h3>
            <p><b>Source:</b> $groupDataSource</p>
            <div class="table-container">
                <table class="data-table">
                    <thead>
                        <tr>
                            <th>Object ID</th>
                            <th>Display Name</th>
                            <th style="text-align: center;">Group Type</th>
                            <th style="text-align: center;">Security</th>
                            <th style="text-align: center;">Mail</th>
                            <th style="text-align: center;">Role Assignable</th>
                            <th style="text-align: center;">Sync</th>
                            <th>Description</th>
                            <th>Mail Address</th>
                            <th>Created Date</th>
                            <th>Membership Rule</th>
                            <th>Collection Time</th>
                        </tr>
                    </thead>
                    <tbody>
$($groupTableRows.ToString())
                    </tbody>
                </table>
            </div>
            <div class="info-note">
                Showing $groupDisplayCount of $groupRecordCount group records (PIM Eligible groups have special badge)
            </div>
        </div>
    </div>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        headers = @{
            "content-type" = "text/html; charset=utf-8"
        }
        Body = $html
    })

} catch {
    $errorMessage = $_.Exception.Message
    $errorStack = $_.ScriptStackTrace

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        headers = @{ "content-type" = "text/html; charset=utf-8" }
        Body = @"
<html>
<head>
    <title>Dashboard Error</title>
    <style>
        body { font-family: sans-serif; padding: 50px; background: #f5f5f5; }
        .error-box { background: #fff; padding: 30px; border-left: 5px solid #d13438; border-radius: 5px; }
        h1 { color: #d13438; margin-top: 0; }
        .error-message { color: #d13438; font-family: monospace; background: #fff3f3; padding: 15px; border-radius: 3px; margin: 15px 0; }
        .stack { font-size: 0.85em; color: #666; font-family: monospace; white-space: pre-wrap; background: #f9f9f9; padding: 10px; border-radius: 3px; }
        .suggestion { background: #e6f2ff; padding: 15px; border-radius: 3px; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="error-box">
        <h1>Data Fetch Error</h1>
        <div class="error-message">$errorMessage</div>
        <div class="stack">$errorStack</div>

        <div class="suggestion">
            <b>Troubleshooting Steps:</b>
            <ol>
                <li>Verify Cosmos DB RBAC permissions are assigned</li>
                <li>Check that Managed Identity has "Cosmos DB Data Contributor" role</li>
                <li>Ensure data exists in the users_raw and groups_raw containers</li>
                <li>Verify Group.Read.All permission is granted</li>
                <li>Try restarting the Function App</li>
            </ol>
        </div>
    </div>
</body>
</html>
"@
    })
}
