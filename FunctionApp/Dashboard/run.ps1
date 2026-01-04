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

    # Render HTML
    $jsonOutput = $dataArray | ConvertTo-Json -Depth 5 -Compress

    # Truncate if too large
    if ($jsonOutput.Length -gt 50000) {
        $jsonOutput = $jsonOutput.Substring(0, 50000) + "`n... (truncated)"
    }

    $html = @"
<html>
<head>
    <title>Entra Risk Dashboard</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding: 25px; background: #f5f5f5; }
        h1 { color: #0078d4; }
        .card { background: #fff; padding: 20px; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .stat { display: inline-block; margin-right: 30px; }
        .stat-label { color: #666; font-size: 0.9em; }
        .stat-value { font-size: 1.5em; font-weight: bold; color: #0078d4; }
        pre { background: #1e1e1e; color: #d4d4d4; padding: 15px; border-radius: 5px; overflow: auto; max-height: 600px; }
        .success { color: #107c10; }
        .warning { color: #ff8c00; }
    </style>
</head>
<body>
    <h1>✓ Entra Risk Data Connected</h1>

    <div class="card">
        <h3>Connection Status</h3>
        <p class="success">✓ Successfully connected to Azure resources</p>
        <p><b>Data Source:</b> $dataSource</p>
        <p><b>Cosmos DB Endpoint:</b> $cosmosEndpoint</p>
        <p><b>Database:</b> $cosmosDatabase</p>
        <p><b>Container:</b> $cosmosContainer</p>
    </div>

    <div class="card">
        <h3>Data Summary</h3>
        <div class="stat">
            <div class="stat-label">User Records</div>
            <div class="stat-value">$recordCount</div>
        </div>
    </div>

    <div class="card">
        <h3>Sample Data (Top Records)</h3>
        <pre>$jsonOutput</pre>
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
