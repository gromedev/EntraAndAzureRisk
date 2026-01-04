using namespace System.Net

param($Request, $TriggerMetadata, $usersRawIn)

# Import the module
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

try {
    # Try to use Cosmos DB data from input binding
    if ($usersRawIn -and $usersRawIn.Count -gt 0) {
        Write-Host "Using Cosmos DB data from input binding ($($usersRawIn.Count) records)"
        $dataArray = $usersRawIn
        $recordCount = $dataArray.Count
        $dataSource = "Cosmos DB (users_raw container via binding)"

    } else {
        # Fallback to Blob Storage
        Write-Host "Cosmos DB binding returned no data, falling back to Blob Storage..."

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

        # Parse XML manually (Invoke-WebRequest doesn't auto-parse XML, avoiding BOM issues)
        [xml]$xmlResponse = $listResponse.Content
        $blobs = $xmlResponse.EnumerationResults.Blobs.Blob

        if (-not $blobs) {
            throw "No blobs found in container. Cosmos error: $cosmosError"
        }

        # Ensure we're working with an array
        if ($blobs -isnot [array]) {
            $blobs = @($blobs)
        }

        $targetBlob = $blobs |
                      Where-Object { $_.Name -like "*-users.jsonl" } |
                      Sort-Object { [DateTime]$_.Properties.'Last-Modified' } -Descending |
                      Select-Object -First 1

        if (-not $targetBlob) {
            $blobNames = ($blobs | ForEach-Object { $_.Name }) -join ", "
            throw "No user JSONL files found. Available blobs: $blobNames. Cosmos error: $cosmosError"
        }

        $blobPath = $targetBlob.Name
        $blobUri = "https://{0}.blob.core.windows.net/{1}/{2}" -f $storageAccountName, $containerName, $blobPath
        $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $storageHeaders

        # Parse JSONL
        $dataArray = @()
        foreach ($line in ($blobContent -split "`n")) {
            if ($line.Trim()) {
                try {
                    $dataArray += $line | ConvertFrom-Json
                } catch {
                    Write-Host "Failed to parse line: $line"
                }
            }
        }

        $recordCount = $dataArray.Count
        $dataSource = "Blob Storage ($blobPath)"
    }

    # Build HTML table rows
    $tableRows = New-Object System.Text.StringBuilder
    $displayCount = [Math]::Min($dataArray.Count, 100)

    for ($i = 0; $i -lt $displayCount; $i++) {
        $user = $dataArray[$i]

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

        # Format last sign-in
        $lastSignIn = if ($user.lastSignInDateTime) {
            try {
                $dt = [DateTime]::Parse($user.lastSignInDateTime)
                $dt.ToString("yyyy-MM-dd HH:mm")
            } catch {
                $user.lastSignInDateTime
            }
        } else {
            "<span class='no-data'>Never</span>"
        }

        # Sync status
        $syncStatus = if ($user.onPremisesSyncEnabled -eq $true) {
            "<span class='badge badge-synced'>Synced</span>"
        } else {
            "<span class='badge badge-cloud'>Cloud-only</span>"
        }

        $upn = if ($user.userPrincipalName) { $user.userPrincipalName } else { "<span class='no-data'>N/A</span>" }
        $displayName = if ($user.displayName) { $user.displayName } else { "<span class='no-data'>N/A</span>" }

        [void]$tableRows.AppendLine(@"
        <tr>
            <td>$displayName</td>
            <td class='upn'>$upn</td>
            <td class='centered'>$statusBadge</td>
            <td class='centered'>$typeBadge</td>
            <td class='centered'>$syncStatus</td>
            <td>$lastSignIn</td>
        </tr>
"@)
    }

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
        .no-data {
            color: #999;
            font-style: italic;
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
</head>
<body>
    <h1>✓ Entra Risk Data Connected</h1>

    <div class="card">
        <h3>Connection Status</h3>
        <p class="success">✓ Successfully connected to Azure resources</p>
        <p><b>Data Source:</b> $dataSource</p>
    </div>

    <div class="card">
        <h3>Data Summary</h3>
        <div class="stat">
            <div class="stat-label">User Records</div>
            <div class="stat-value">$recordCount</div>
        </div>
    </div>

    <div class="card">
        <h3>User Data</h3>
        <div class="table-container">
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Display Name</th>
                        <th>User Principal Name</th>
                        <th style="text-align: center;">Status</th>
                        <th style="text-align: center;">Type</th>
                        <th style="text-align: center;">Sync</th>
                        <th>Last Sign-In</th>
                    </tr>
                </thead>
                <tbody>
$($tableRows.ToString())
                </tbody>
            </table>
        </div>
        <div class="info-note">
            Showing $displayCount of $recordCount records
        </div>
    </div>
</body>
</html>
"@

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    # Use lowercase 'headers' and ensure Content-Type is exact
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
        # Change this to lowercase 'headers' as well
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
        <h1>⚠️ Data Fetch Error</h1>
        <div class="error-message">$errorMessage</div>
        <div class="stack">$errorStack</div>

        <div class="suggestion">
            <b>Troubleshooting Steps:</b>
            <ol>
                <li>Verify Cosmos DB RBAC permissions are assigned</li>
                <li>Check that Managed Identity has "Cosmos DB Data Contributor" role</li>
                <li>Ensure data exists in the users_raw container</li>
                <li>Try restarting the Function App</li>
            </ol>
        </div>
    </div>
</body>
</html>
"@
    })
}
