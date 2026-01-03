using namespace System.Net

param($Request, $TriggerMetadata)

# 1. Import the module
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

try {
    #region Configuration
    $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
    $cosmosDatabase = $env:COSMOS_DB_DATABASE

    if (-not $cosmosEndpoint -or -not $cosmosDatabase) {
        throw "Cosmos DB configuration missing."
    }
    #endregion

    #region Token Acquisition
    Write-Host "Getting Managed Identity Token..."
    $rawToken = Get-CachedManagedIdentityToken -Resource "https://cosmos.azure.com"
    
    # Format the token correctly for the Data Plane
    $cosmosToken = "type=aad&ver=1.0&sig=$rawToken"
    #endregion

    #region Fetch Data
    $script:snapshotData = @()
    $snapshotQuery = "SELECT * FROM c"

    # This calls the updated 'smart' function in your .psm1
    Get-CosmosDocuments -Endpoint $cosmosEndpoint `
        -Database $cosmosDatabase `
        -Container "snapshots" `
        -Query $snapshotQuery `
        -AccessToken $cosmosToken `
        -ProcessPage {
            param($Documents)
            $script:snapshotData += $Documents
        }
    #endregion

    #region Render HTML
    $snapshotJson = $script:snapshotData | ConvertTo-Json -Depth 10
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Dashboard</title>
    <style>body{font-family:sans-serif;padding:20px;} pre{background:#eee;padding:15px;}</style>
</head>
<body>
    <h1>Cosmos Data</h1>
    <p>Items found: $($script:snapshotData.Count)</p>
    <pre>$snapshotJson</pre>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers = @{ "Content-Type" = "text/html; charset=utf-8" }
        Body = $html
    })

} catch {
    $errorHtml = "<html><body><h1>Error</h1><pre>$($_.Exception.Message)</pre></body></html>"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers = @{ "Content-Type" = "text/html; charset=utf-8" }
        Body = $errorHtml
    })
}