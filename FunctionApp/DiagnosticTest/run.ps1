using namespace System.Net

param($Request, $TriggerMetadata)

$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

$results = @()
$allPassed = $true

# Test 1: Check environment variables
$results += "=== TEST 1: Environment Variables ==="
$storageAccountName = $env:STORAGE_ACCOUNT_NAME
if ($storageAccountName) {
    $results += "[PASS] STORAGE_ACCOUNT_NAME = $storageAccountName"
} else {
    $results += "[FAIL] STORAGE_ACCOUNT_NAME is not set"
    $allPassed = $false
}

$results += ""

# Test 2: Check Managed Identity environment
$results += "=== TEST 2: Managed Identity Environment ==="
if ($env:IDENTITY_ENDPOINT) {
    $results += "[PASS] IDENTITY_ENDPOINT = $($env:IDENTITY_ENDPOINT)"
} else {
    $results += "[FAIL] IDENTITY_ENDPOINT not found"
    $allPassed = $false
}

if ($env:IDENTITY_HEADER) {
    $results += "[PASS] IDENTITY_HEADER = $($env:IDENTITY_HEADER.Substring(0, 20))..."
} else {
    $results += "[FAIL] IDENTITY_HEADER not found"
    $allPassed = $false
}

$results += ""

# Test 3: Try to get a token
$results += "=== TEST 3: Acquire Storage Token ==="
try {
    $storageToken = Get-ManagedIdentityToken -Resource "https://storage.azure.com"
    if ($storageToken) {
        $results += "[PASS] Token acquired"
        $results += "  Token length: $($storageToken.Length)"
        $results += "  Token prefix: $($storageToken.Substring(0, 30))..."

        # Decode token to check claims (without validation)
        try {
            $tokenParts = $storageToken.Split('.')
            if ($tokenParts.Length -ge 2) {
                $payload = $tokenParts[1]
                # Add padding if needed
                while ($payload.Length % 4 -ne 0) { $payload += "=" }
                $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
                $claims = $payloadJson | ConvertFrom-Json
                $results += "  Token audience: $($claims.aud)"
                $results += "  Token expires: $(([DateTimeOffset]::FromUnixTimeSeconds($claims.exp)).DateTime)"
            }
        } catch {
            $results += "  (Could not decode token claims: $_)"
        }
    } else {
        $results += "[FAIL] Token is null or empty"
        $allPassed = $false
    }
} catch {
    $results += "[FAIL] Failed to acquire token: $_"
    $allPassed = $false
    $storageToken = $null
}

$results += ""

# Test 4: Try to access storage
if ($storageToken -and $storageAccountName) {
    $results += "=== TEST 4: Test Storage Access ==="

    $containerName = "raw-data"
    $listUri = "https://{0}.blob.core.windows.net/{1}?restype=container&comp=list" -f $storageAccountName, $containerName

    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version'   = '2021-08-06'
        'x-ms-date'      = [DateTime]::UtcNow.ToString('r')
    }

    $results += "  Request URI: $listUri"
    $results += "  Headers:"
    $results += "    Authorization: Bearer <token>"
    $results += "    x-ms-version: 2021-08-06"
    $results += "    x-ms-date: $($headers['x-ms-date'])"
    $results += ""

    try {
        $response = Invoke-WebRequest -Uri $listUri -Method Get -Headers $headers -ErrorAction Stop
        $results += "[PASS] Storage API call succeeded"
        $results += "  Status Code: $($response.StatusCode)"
        $results += "  Content Length: $($response.Content.Length)"

        # Parse response
        [xml]$xmlContent = $response.Content
        $blobCount = $xmlContent.EnumerationResults.Blobs.Blob.Count
        $results += "  Blob count: $blobCount"

    } catch {
        $results += "[FAIL] Storage API call failed"
        $results += "  Exception: $($_.Exception.Message)"

        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $results += "  Status Code: $statusCode"
            $results += "  Status Description: $($_.Exception.Response.StatusDescription)"

            # Try to read response body
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $results += "  Response Body: $responseBody"
            } catch {
                $results += "  (Could not read response body)"
            }
        }
        $allPassed = $false
    }
} else {
    $results += "=== TEST 4: Test Storage Access ==="
    $results += "[SKIP] Skipped because token or storage account name not available"
}

$results += ""
$results += "========================================"
if ($allPassed) {
    $results += "ALL TESTS PASSED ✓"
} else {
    $results += "SOME TESTS FAILED ✗"
}
$results += "========================================"

$output = $results -join "`n"

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers = @{ "Content-Type" = "text/plain; charset=utf-8" }
    Body = $output
})
