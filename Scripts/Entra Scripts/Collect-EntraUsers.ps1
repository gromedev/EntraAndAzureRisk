#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Entra ID user data with parallel processing
#>

[CmdletBinding()]
param()

# Import modules

Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\..\Modules\Entra.Functions.psm1")) -Force
Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\..\Modules\Common.Functions.psm1")) -Force

# Get configuration
$config = Get-Config -ConfigPath (Join-Path $PSScriptRoot "..\..\Modules\giam-config.json") -Force -Verbose
Initialize-DataPaths -Config $config

write-host $PSScriptRoot

# Setup paths
$timestamp = Get-Date -Format $config.FileManagement.DateFormat
$tempPath = Join-Path $config.Paths.Temp "$($config.FilePrefixes.EntraUsers)_$timestamp.csv"

# Initialize CSV with IdentityTool headers (exact match)
$csvHeader = "`"UserIdentifier`",`"UserPrincipalName`",`"Id`",`"accountEnabled`",`"UserType`",`"assignedLicenses`",`"CustomSecurityAttributes`",`"createdDateTime`",`"LastSignInDateTime`",`"OnPremisesSyncEnabled`",`"OnPremisesSamAccountName`",`"PasswordPolicies`""
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

# Initialize mutex for thread-safe file writing
# Old version - EntraUsers slow
#$mutex = [System.Threading.Mutex]::new($false, "EntraUsersCSVMutex")

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Get SKU mapping
    Write-Host "Getting license SKU mappings..."

    # Get SKU mapping directly
    $skus = Get-MgSubscribedSku
    $skuLookup = @{}
    foreach ($sku in $skus) {
        $skuLookup[$sku.SkuId] = $sku.SkuPartNumber
    }
    
    # Get SKU mapping directly
    $skus = Get-MgSubscribedSku
    $skuLookup = @{}
    foreach ($sku in $skus) {
        $skuLookup[$sku.SkuId] = $sku.SkuPartNumber
    }

    # Initialize batch processing
    $batchSize = $config.EntraID.BatchSize
    $totalProcessed = 0
    $batchNumber = 0
    
    #$nextLink = "https://graph.microsoft.com/v1.0/users?`$select=userPrincipalName,id,accountEnabled,userType,assignedLicenses,customSecurityAttributes,createdDateTime,signInActivity,onPremisesSyncEnabled,onPremisesSamAccountName,passwordPolicies&`$top=$batchSize"
    
    <# Allows filtering groups
    see giam-config.json:
        "TargetGroup": null,
        "ScopeToGroup": false
    #>
    $nextLink = Get-InitialUserQuery -Config $config.EntraID -SelectFields "userPrincipalName,id,accountEnabled,userType,assignedLicenses,customSecurityAttributes,createdDateTime,signInActivity,onPremisesSyncEnabled,onPremisesSamAccountName,passwordPolicies" -BatchSize $batchSize
    Write-Host "Starting user collection..."
    
    while ($nextLink) {
        $batchNumber++
        Write-Host "Processing batch $batchNumber..."
        
        # FIXED: Check memory only every 10 batches
        if ($batchNumber % 10 -eq 0) {
            if (Test-MemoryPressure -ThresholdGB $config.EntraID.MemoryThresholdGB `
                                    -WarningGB $config.EntraID.MemoryWarningThresholdGB) {
                # Memory cleanup handled in function
            }
        }
        
        <# Get batch - older, slower version
        $batchData = Get-GraphBatch -NextLink $nextLink -Config $config.EntraID
        $users = $batchData.Items
        $nextLink = $batchData.NextLink
        #>

        # Get batch directly
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink
        $users = $response.value
        $nextLink = $response.'@odata.nextLink'
        
        if ($users.Count -gt 0) {
            # Pre-convert dates before parallel processing
            foreach ($user in $users) {
                $user | Add-Member -NotePropertyName 'StandardCreatedDateTime' -NotePropertyValue $(
                    if ($user.createdDateTime) { 
                        Convert-ToStandardDateTime -DateValue $user.createdDateTime -SourceFormat 'GraphAPI' 
                    } else { "" }
                )
                $user | Add-Member -NotePropertyName 'StandardLastSignInDateTime' -NotePropertyValue $(
                    if ($user.signInActivity.lastSignInDateTime) { 
                        Convert-ToStandardDateTime -DateValue $user.signInActivity.lastSignInDateTime -SourceFormat 'GraphAPI' 
                    } else { "" }
                )
            }

            foreach ($user in $users) {
    $user | Add-Member -NotePropertyName 'StandardAccountEnabled' -NotePropertyValue $(
        if ($null -ne $user.accountEnabled) { if ($user.accountEnabled) { "1" } else { "0" } } else { "" }
    )
    $user | Add-Member -NotePropertyName 'StandardOnPremisesSyncEnabled' -NotePropertyValue $(
        if ($null -ne $user.onPremisesSyncEnabled) { if ($user.onPremisesSyncEnabled) { "1" } else { "0" } } else { "" }
    )
}
            
            # Process users in parallel
            $batchResults = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            
            $users | ForEach-Object -ThrottleLimit $config.EntraID.ParallelThrottle -Parallel {
                $user = $_
                $localBatchResults = $using:batchResults
                $localSkuLookup = $using:skuLookup
                $errorValue = ""
                
                try {
                    # Extract UserIdentifier
                    $userIdentifier = ($user.userPrincipalName -split '@')[0]
                    
                    # Convert licenses to SKU names
                    $licenses = if ($user.assignedLicenses) {
                        ($user.assignedLicenses.skuId | ForEach-Object { 
                            $localSkuLookup[$_] 
                        } | Where-Object { $_ }) -join ' | '
                    } else { $errorValue }
                    
                    # Handle custom attributes
                    $attributes = if ($user.customSecurityAttributes -and 
                                     ($user.customSecurityAttributes | ConvertTo-Json -Compress) -ne "null") {
                        $user.customSecurityAttributes | ConvertTo-Json -Compress
                    } else { $errorValue }
                    
                    # Use pre-converted date values
                    $createdDateTime = if ($user.StandardCreatedDateTime) { $user.StandardCreatedDateTime } else { $errorValue }
                    $lastSignInDateTime = if ($user.StandardLastSignInDateTime) { $user.StandardLastSignInDateTime } else { $errorValue }
                    
                    $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`",`"{4}`",`"{5}`",`"{6}`",`"{7}`",`"{8}`",`"{9}`",`"{10}`",`"{11}`"" -f `
                        $userIdentifier,
                        ($user.userPrincipalName ?? $errorValue),
                        ($user.id ?? $errorValue),
                        ($user.StandardAccountEnabled ?? $errorValue),
                        ($user.userType ?? $errorValue),
                        $licenses,
                        $attributes,
                        $createdDateTime,
                        $lastSignInDateTime,
                        ($user.StandardOnPremisesSyncEnabled ?? $errorValue),
                        ($user.onPremisesSamAccountName ?? $errorValue),
                        ($user.passwordPolicies ?? $errorValue)
                    
                    $localBatchResults.Add($line)
                }
                catch {
                    Write-Warning "Error processing user $($user.userPrincipalName): $_"
                }
            }
            
            # FIXED: Write batch to file without mutex
            if ($batchResults.Count -gt 0) {
                $batchResults | Add-Content -Path $tempPath -Encoding UTF8
                $totalProcessed += $users.Count
                Write-Host "Completed batch $batchNumber. Total users processed: $totalProcessed"
            }
        }
    }
    
    Write-Host "Processing complete. Total users processed: $totalProcessed"
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "$($config.FilePrefixes.EntraUsers)_$timestamp.csv" -Config $config
}
catch {
    Write-Error "Error collecting Entra users: $_"
    throw
}
finally {
    # REMOVED: if ($mutex) { $mutex.Dispose() }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}s
