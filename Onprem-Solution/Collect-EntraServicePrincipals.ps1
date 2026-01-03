#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Entra ID service principal data with parallel processing
.DESCRIPTION
    Collects comprehensive service principal information from Microsoft Entra ID including
    app roles, OAuth2 permissions, and configuration details
#>

[CmdletBinding()]
param()

# Import modules
Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\..\Modules\Entra.Functions.psm1")) -Force
Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\..\Modules\Common.Functions.psm1")) -Force

# Get configuration
$config = Get-Config -ConfigPath (Join-Path $PSScriptRoot "..\..\Modules\giam-config.json") -Force -Verbose
Initialize-DataPaths -Config $config

Write-Host $PSScriptRoot

# Setup paths
$timestamp = Get-Date -Format $config.FileManagement.DateFormat
$tempPath = Join-Path $config.Paths.Temp "GIAM-EntraServicePrincipals_$timestamp.csv"

# Initialize CSV with headers for service principals - verified properties from Graph API docs
$csvHeader = "`"UserIdentifier`",`"accountEnabled`",`"addIns`",`"displayName`",`"appDescription`",`"appId`",`"appRoleAssignmentRequired`",`"deletedDateTime`",`"description`",`"oauth2PermissionScopes`",`"preferredSingleSignOnMode`",`"resourceSpecificApplicationPermissions`",`"servicePrincipalNames`",`"servicePrincipalType`",`"tags`""
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

# Initialize mutex for thread-safe file writing (from EntraUserGroups pattern)
$mutex = [System.Threading.Mutex]::new($false, "EntraServicePrincipalsCSVMutex")

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Initialize processing variables
    $resultBuffer = [System.Collections.Generic.List[string]]::new()
    $totalProcessed = 0
    $batchNumber = 0
    
    # Initialize batch processing
    $batchSize = $config.EntraID.BatchSize
    
    # Define the select fields for service principals - verified against Graph API v1.0 documentation
    # Note: appDescription and preferredSingleSignOnMode may not be available in v1.0, using available alternatives
    $selectFields = "appDisplayName,accountEnabled,addIns,displayName,appId,appRoleAssignmentRequired,deletedDateTime,description,oauth2PermissionScopes,resourceSpecificApplicationPermissions,servicePrincipalNames,servicePrincipalType,tags,notes"
    
    # Build initial query for service principals - direct endpoint, no user filtering needed
    $nextLink = "https://graph.microsoft.com/v1.0/serviceprincipals?`$select=$selectFields&`$top=$batchSize"
    
    Write-Host "Starting service principal collection..."
    
    while ($nextLink) {
        $batchNumber++
        Write-Host "Processing batch $batchNumber..."
        
        # Check memory pressure every 10 batches (from EntraUsers pattern)
        if ($batchNumber % 10 -eq 0) {
            if (Test-MemoryPressure -ThresholdGB $config.EntraID.MemoryThresholdGB `
                                    -WarningGB $config.EntraID.MemoryWarningThresholdGB) {
                # Write buffer when memory pressure detected
                if ($resultBuffer.Count -gt 0) {
                    Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
                }
            }
        }
        
        # Get batch using Graph API retry logic (from Entra.Functions.psm1)
        $batchData = Get-GraphBatch -NextLink $nextLink -Config $config.EntraID
        $servicePrincipals = $batchData.Items
        $nextLink = $batchData.NextLink
        
        if ($servicePrincipals.Count -gt 0) {
            # Pre-convert dates and booleans before parallel processing (EntraUsers pattern)
            foreach ($sp in $servicePrincipals) {
                # Standardize boolean values
                $sp | Add-Member -NotePropertyName 'StandardAccountEnabled' -NotePropertyValue $(
                    if ($null -ne $sp.accountEnabled) { if ($sp.accountEnabled) { "1" } else { "0" } } else { "" }
                )
                $sp | Add-Member -NotePropertyName 'StandardAppRoleAssignmentRequired' -NotePropertyValue $(
                    if ($null -ne $sp.appRoleAssignmentRequired) { if ($sp.appRoleAssignmentRequired) { "1" } else { "0" } } else { "" }
                )
                
                # Convert datetime
                $sp | Add-Member -NotePropertyName 'StandardDeletedDateTime' -NotePropertyValue $(
                    if ($sp.deletedDateTime) { 
                        Convert-ToStandardDateTime -DateValue $sp.deletedDateTime -SourceFormat 'GraphAPI' 
                    } else { "" }
                )
            }
            
            # Process service principals in parallel (EntraUserGroups pattern)
            $batchResults = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            
            $servicePrincipals | ForEach-Object -ThrottleLimit $config.EntraID.ParallelThrottle -Parallel {
                # Import module in parallel scope (EntraUserGroups pattern)
                Import-Module "D:\ID-Tool\Modules\Entra.Functions.psm1" -Force
                
                $sp = $_
                $localBatchResults = $using:batchResults
                $errorValue = ""
                
                try {
                    # Extract UserIdentifier from appDisplayName (or fallback to displayName) 
                    $userIdentifier = if ($sp.appDisplayName) { 
                        $sp.appDisplayName 
                    } elseif ($sp.displayName) { 
                        $sp.displayName 
                    } else { 
                        $sp.appId ?? "" 
                    }
                    
                    # Process addIns array safely
                    $addIns = if ($sp.addIns -and $sp.addIns.Count -gt 0) {
                        ($sp.addIns | ForEach-Object { $_.type } | Select-Object -First 10) -join ' | '
                    } else { $errorValue }
                    
                    # Clean up text fields for CSV safety (following EntraUsers pattern)
                    $cleanDescription = if ($sp.description) {
                        ($sp.description -replace "`r`n", " " -replace "`n", " " -replace "`t", " " -replace '"', '""').Trim()
                    } else { $errorValue }
                    
                    $cleanNotes = if ($sp.notes) {
                        ($sp.notes -replace "`r`n", " " -replace "`n", " " -replace "`t", " " -replace '"', '""').Trim()
                    } else { $errorValue }
                    
                    # Process oauth2PermissionScopes array
                    $oauth2PermissionScopes = if ($sp.oauth2PermissionScopes -and $sp.oauth2PermissionScopes.Count -gt 0) {
                        ($sp.oauth2PermissionScopes | ForEach-Object { $_.value } | Select-Object -First 20) -join ' | '
                    } else { $errorValue }
                    
                    # Process resourceSpecificApplicationPermissions array
                    $resourceSpecificApplicationPermissions = if ($sp.resourceSpecificApplicationPermissions -and $sp.resourceSpecificApplicationPermissions.Count -gt 0) {
                        ($sp.resourceSpecificApplicationPermissions | ForEach-Object { $_.value } | Select-Object -First 10) -join ' | '
                    } else { $errorValue }
                    
                    # Process servicePrincipalNames array
                    $servicePrincipalNames = if ($sp.servicePrincipalNames -and $sp.servicePrincipalNames.Count -gt 0) {
                        ($sp.servicePrincipalNames | Select-Object -First 15) -join ' | '
                    } else { $errorValue }
                    
                    # Process tags array
                    $tags = if ($sp.tags -and $sp.tags.Count -gt 0) {
                        ($sp.tags | Select-Object -First 10) -join ' | '
                    } else { $errorValue }
                    
                    # Format CSV line following EntraUserGroups pattern - updated for corrected fields
                    $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`",`"{4}`",`"{5}`",`"{6}`",`"{7}`",`"{8}`",`"{9}`",`"{10}`",`"{11}`",`"{12}`",`"{13}`"" -f `
                        ($userIdentifier -replace '"', '""'),
                        ($sp.StandardAccountEnabled ?? $errorValue),
                        ($addIns -replace '"', '""'),
                        (($sp.displayName ?? $errorValue) -replace '"', '""'),
                        $cleanNotes,
                        ($sp.appId ?? $errorValue),
                        ($sp.StandardAppRoleAssignmentRequired ?? $errorValue),
                        ($sp.StandardDeletedDateTime ?? $errorValue),
                        $cleanDescription,
                        ($oauth2PermissionScopes -replace '"', '""'),
                        ($resourceSpecificApplicationPermissions -replace '"', '""'),
                        ($servicePrincipalNames -replace '"', '""'),
                        (($sp.servicePrincipalType ?? $errorValue) -replace '"', '""'),
                        ($tags -replace '"', '""')
                    
                    $localBatchResults.Add($line)
                }
                catch {
                    Write-Warning "Error processing service principal $($sp.displayName): $_"
                }
            }
            
            # Write batch to file (thread-safe) and add to main buffer - hybrid approach
            if ($batchResults.Count -gt 0) {
                # Add to main buffer for memory management
                foreach ($result in $batchResults) {
                    $resultBuffer.Add($result)
                }
                
                # Write buffer when full (following EntraUsers pattern)
                if ($resultBuffer.Count -ge $config.ActiveDirectory.BufferLimit) {
                    try {
                        $mutex.WaitOne() | Out-Null
                        Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
                    }
                    finally {
                        $mutex.ReleaseMutex()
                    }
                }
                
                $totalProcessed += $servicePrincipals.Count
                Write-Host "Completed batch $batchNumber. Total service principals processed: $totalProcessed"
            }
        }
        
        # Clear batch data to manage memory (EntraUserGroups pattern)
        $servicePrincipals = $null
        $batchData = $null
        
        # Force garbage collection every 20 batches
        if ($batchNumber % 20 -eq 0) {
            [System.GC]::Collect()
        }
    }
    
    # Write remaining buffer
    if ($resultBuffer.Count -gt 0) {
        try {
            $mutex.WaitOne() | Out-Null
            Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
    
    Write-Host "Processing complete! Total service principals processed: $totalProcessed" -ForegroundColor Green
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "GIAM-EntraServicePrincipals_$timestamp.csv" -Config $config
}
catch {
    Write-Error "Error collecting Entra service principals: $_"
    throw
}
finally {
    # Clean up
    if ($resultBuffer) { 
        $resultBuffer.Clear()
        $resultBuffer = $null
    }
    if ($mutex) { 
        $mutex.Dispose() 
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}