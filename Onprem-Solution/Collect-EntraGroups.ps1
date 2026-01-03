#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Entra ID cloud-only groups with parallel processing - FIXED VERSION
.DESCRIPTION
    FIXED: Both CSV corruption from field escaping AND isAssignableToRole using beta endpoint
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
$tempPath = Join-Path $config.Paths.Temp "GIAM-EntraGroups_$timestamp.csv"

# Initialize CSV with headers - adapted for groups
$csvHeader = "`"GroupIdentifier`",`"Id`",`"classification`",`"deletedDateTime`",`"description`",`"groupTypes`",`"mailEnabled`",`"membershipRule`",`"securityEnabled`",`"isAssignableToRole`""
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

Write-Host "CSV Header created with 10 fields in order:" -ForegroundColor Yellow
Write-Host "1. GroupIdentifier, 2. Id, 3. classification, 4. deletedDateTime, 5. description" -ForegroundColor Gray  
Write-Host "6. groupTypes, 7. mailEnabled, 8. membershipRule, 9. securityEnabled, 10. isAssignableToRole" -ForegroundColor Gray

# FIXED: Proper CSV escaping function with explicit empty quotes for nulls
function ConvertTo-SafeCSV {
    param([string]$Value)
    
    if ([string]::IsNullOrEmpty($Value)) {
        return '""'  # FIXED: Returns ,"", instead of ,,
    }
    
    # Remove dangerous characters that break CSV structure
    $cleanValue = $Value -replace "`r`n", " " -replace "`n", " " -replace "`r", " " -replace "`t", " "
    $cleanValue = $cleanValue -replace '\s+', ' '  # Collapse multiple spaces
    $cleanValue = $cleanValue.Trim()
    
    # CRITICAL: Escape double quotes for CSV (MUST be done before wrapping in quotes)
    $cleanValue = $cleanValue -replace '"', '""'
    
    # Return with quotes (this handles commas safely)
    return "`"$cleanValue`""
}

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Initialize batch processing
    $batchSize = $config.EntraID.BatchSize
    $totalProcessed = 0
    $batchNumber = 0
    
    # FIXED: Use BETA endpoint for reliable isAssignableToRole values
    $selectFields = "displayName,id,classification,deletedDateTime,description,groupTypes,mailEnabled,membershipRule,securityEnabled,isAssignableToRole,onPremisesSyncEnabled"
    
    # BETA endpoint - should return actual true/false values for isAssignableToRole
    $nextLink = "https://graph.microsoft.com/beta/groups?`$select=$selectFields&`$top=$batchSize"
    
    Write-Host "FIXED: Using BETA endpoint for reliable isAssignableToRole values" -ForegroundColor Cyan
    Write-Host "Starting cloud-only groups collection..."
    
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
        
        # Get batch directly BUT with beta endpoint
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink
        $groups = $response.value
        $nextLink = $response.'@odata.nextLink'
        
        if ($groups.Count -gt 0) {
            # Pre-convert dates before parallel processing
            foreach ($group in $groups) {
                $group | Add-Member -NotePropertyName 'StandardDeletedDateTime' -NotePropertyValue $(
                    if ($group.deletedDateTime) { 
                        Convert-ToStandardDateTime -DateValue $group.deletedDateTime -SourceFormat 'GraphAPI' 
                    } else { "" }
                )
            }

            # Pre-convert boolean values before parallel processing
            foreach ($group in $groups) {
                $group | Add-Member -NotePropertyName 'StandardMailEnabled' -NotePropertyValue $(
                    if ($null -ne $group.mailEnabled) { if ($group.mailEnabled) { "1" } else { "0" } } else { "" }
                )
                $group | Add-Member -NotePropertyName 'StandardSecurityEnabled' -NotePropertyValue $(
                    if ($null -ne $group.securityEnabled) { if ($group.securityEnabled) { "1" } else { "0" } } else { "" }
                )
                $group | Add-Member -NotePropertyName 'StandardIsAssignableToRole' -NotePropertyValue $(
                    if ($null -ne $group.isAssignableToRole) { 
                        if ($group.isAssignableToRole) { "1" } else { "0" } 
                    } else { "" }
                )
                
                # FIXED: Debug tracking for isAssignableToRole actual values from beta endpoint
                if ($group.isAssignableToRole -eq $true) {
                    Write-Host "SUCCESS: Found role-assignable group: $($group.displayName)" -ForegroundColor Green
                } elseif ($group.isAssignableToRole -eq $false) {
                    Write-Host "INFO: Found non-role-assignable group: $($group.displayName)" -ForegroundColor Yellow
                }
            }
            
            # Process groups in parallel
            $batchResults = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            
            $groups | ForEach-Object -ThrottleLimit $config.EntraID.ParallelThrottle -Parallel {
                # FIXED: Import the CSV function in parallel scope with proper null handling
                function ConvertTo-SafeCSV {
                    param([string]$Value)
                    if ([string]::IsNullOrEmpty($Value)) { 
                        return '""'  # FIXED: Returns ,"", instead of ,,
                    }
                    $cleanValue = $Value -replace "`r`n", " " -replace "`n", " " -replace "`r", " " -replace "`t", " "
                    $cleanValue = $cleanValue -replace '\s+', ' '
                    $cleanValue = $cleanValue.Trim()
                    $cleanValue = $cleanValue -replace '"', '""'
                    return "`"$cleanValue`""
                }
                
                $group = $_
                $localBatchResults = $using:batchResults
                $errorValue = ""
                
                try {
                    # FIXED: Use continue instead of return to avoid parallel processing issues
                    if ($group.onPremisesSyncEnabled -eq $true) {
                        continue  # Skip AD-synced groups
                    }
                    
                    # Extract GroupIdentifier from displayName (equivalent to UserIdentifier logic)
                    $groupIdentifier = ConvertTo-SafeCSV -Value ($group.displayName ?? $errorValue)
                    
                    # FIXED: Properly escape groupTypes array
                    $groupTypesString = if ($group.groupTypes -and $group.groupTypes.Count -gt 0) {
                        $safeTypes = $group.groupTypes | ForEach-Object { 
                            $_ -replace '"', '""' -replace ",", ";" -replace "`r`n", " " 
                        }
                        ConvertTo-SafeCSV -Value ($safeTypes -join ' | ')
                    } else { ConvertTo-SafeCSV -Value $errorValue }
                    
                    # Use pre-converted date values
                    $deletedDateTime = ConvertTo-SafeCSV -Value ($group.StandardDeletedDateTime ?? $errorValue)
                    
                    # FIXED: Properly escape ALL text fields that could contain commas/quotes/line breaks
                    $classification = ConvertTo-SafeCSV -Value ($group.classification ?? $errorValue)
                    $description = ConvertTo-SafeCSV -Value ($group.description ?? $errorValue)
                    $membershipRule = ConvertTo-SafeCSV -Value ($group.membershipRule ?? $errorValue)
                    
                    # FIXED: Create line with ALL fields properly escaped - NO additional quotes needed
                    $line = "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}" -f `
                        $groupIdentifier,
                        (ConvertTo-SafeCSV -Value ($group.id ?? $errorValue)),
                        $classification,
                        $deletedDateTime,
                        $description,
                        $groupTypesString,
                        (ConvertTo-SafeCSV -Value ($group.StandardMailEnabled ?? $errorValue)),
                        $membershipRule,
                        (ConvertTo-SafeCSV -Value ($group.StandardSecurityEnabled ?? $errorValue)),
                        (ConvertTo-SafeCSV -Value ($group.StandardIsAssignableToRole ?? $errorValue))
                    
                    # FIXED: Verify field count to catch data bleed
                    $fieldCount = ($line -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)').Count  # CSV-aware comma counting
                    if ($fieldCount -ne 10) {
                        Write-Warning "FIELD COUNT MISMATCH for group $($group.displayName): Expected 10 fields, got $fieldCount"
                        Write-Host "Problem line: $line" -ForegroundColor Red
                    }
                    
                    $localBatchResults.Add($line)
                }
                catch {
                    Write-Warning "Error processing group $($group.displayName): $_"
                }
            }
            
            # FIXED: Write batch to file without mutex
            if ($batchResults.Count -gt 0) {
                $batchResults | Add-Content -Path $tempPath -Encoding UTF8
                $totalProcessed += $groups.Count
                Write-Host "Completed batch $batchNumber. Total groups processed: $totalProcessed"
            }
        }
    }
    
    Write-Host "Processing complete. Total cloud-only groups processed: $totalProcessed" -ForegroundColor Green
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "GIAM-EntraGroups_$timestamp.csv" -Config $config
}
catch {
    Write-Error "Error collecting Entra groups: $_"
    throw
}
finally {
    # FIXED: Cleanup
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}