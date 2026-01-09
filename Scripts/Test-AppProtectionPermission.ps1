# Test-AppProtectionPermission.ps1
# Quick test to check if the Function App's managed identity can access App Protection APIs
# Run this against the Function App directly via REST API

param(
    [string]$FunctionAppName = "func-entrariskv35-data-dev-enkqnnv64liny",
    [string]$ResourceGroup = "rg-entrarisk-v35-001"
)

Write-Host "=== Testing App Protection API Access ===" -ForegroundColor Cyan

# Get the function key
Write-Host "Getting function key..."
$funcKey = az functionapp keys list --name $FunctionAppName --resource-group $ResourceGroup --query "functionKeys.default" -o tsv 2>$null

if (-not $funcKey) {
    Write-Error "Failed to get function key"
    exit 1
}

# Create a simple HTTP trigger to test Graph API access
# We'll use the existing HttpTrigger function to run arbitrary code

$testScript = @'
# Test script to verify Graph API access for App Protection
try {
    # Get managed identity token
    $tokenResponse = Invoke-RestMethod -Uri "$env:IDENTITY_ENDPOINT?resource=https://graph.microsoft.com&api-version=2019-08-01" `
                                        -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER } `
                                        -Method Get
    $token = $tokenResponse.access_token

    Write-Host "Got managed identity token"

    # Test iOS MAM endpoint
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    Write-Host "Testing iOS MAM endpoint..."
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceAppManagement/iosManagedAppProtections?`$top=5" `
                                   -Headers $headers `
                                   -Method Get `
                                   -ErrorAction Stop

    Write-Host "SUCCESS! Found $($response.value.Count) iOS app protection policies"
    $response.value | ForEach-Object { Write-Host "  - $($_.displayName)" }

    return @{ Success = $true; Count = $response.value.Count; Policies = ($response.value | Select-Object -Property id, displayName) }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host $_.ErrorDetails.Message -ForegroundColor Red
    }
    return @{ Success = $false; Error = $_.Exception.Message }
}
'@

# For now, let's just check if we can get app protection policies via the Dashboard
# The Dashboard reads from Cosmos DB, so let's check what the collector actually wrote

Write-Host ""
Write-Host "=== Checking Latest Collection Results ===" -ForegroundColor Cyan

# Get latest blob
$latestBlobs = az storage blob list `
    --account-name "stentrariskv35devenkqnnv" `
    --container-name "raw-data" `
    --auth-mode login `
    --query "[?contains(name, 'policies')].{name:name, modified:properties.lastModified}" `
    -o json 2>$null | ConvertFrom-Json

$latestBlob = $latestBlobs | Sort-Object -Property modified -Descending | Select-Object -First 1

Write-Host "Latest policies blob: $($latestBlob.name)"
Write-Host "Last modified: $($latestBlob.modified)"

# Download and check
$tempFile = "$env:TEMP/policies-test.jsonl"
az storage blob download `
    --account-name "stentrariskv35devenkqnnv" `
    --container-name "raw-data" `
    --name $latestBlob.name `
    --auth-mode login `
    --file $tempFile 2>$null | Out-Null

# Count policy types
$policies = Get-Content $tempFile | ForEach-Object { $_ | ConvertFrom-Json }
$policyTypes = $policies | Group-Object -Property policyType

Write-Host ""
Write-Host "Policy Types in blob:" -ForegroundColor Yellow
$policyTypes | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }

$appProtection = $policyTypes | Where-Object { $_.Name -eq 'appProtectionPolicy' }
if ($appProtection) {
    Write-Host ""
    Write-Host "App Protection Policies:" -ForegroundColor Green
    $appProtection.Group | ForEach-Object { Write-Host "  - $($_.displayName)" }
} else {
    Write-Host ""
    Write-Host "NO App Protection Policies found in blob!" -ForegroundColor Red
    Write-Host "This means the collector is failing to retrieve them from Graph API"
}
