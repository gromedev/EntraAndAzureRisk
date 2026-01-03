#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Entra ID user group memberships with parallel processing
#>
[CmdletBinding()]
param()

# Import modules
Import-Module (Join-Path $PSScriptRoot "..\..\Modules\Entra.Functions.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\Modules\Common.Functions.psm1") -Force

# Get configuration
$config = Get-Config -ConfigPath (Join-Path $PSScriptRoot "..\..\Modules\giam-config.json") -Force -Verbose
Initialize-DataPaths -Config $config

# Setup paths
$timestamp = Get-Date -Format $config.FileManagement.DateFormat
$tempPath = Join-Path $config.Paths.Temp "$($config.FilePrefixes.EntraGroups)_$timestamp.csv"

# Initialize CSV with IdentityTool headers (exact match)
$csvHeader = "`"UserIdentifier`",`"UPN`",`"GroupName`",`"GroupRoleAssignable`",`"GroupType`",`"GroupMembershipType`",`"GroupSecurityEnabled`",`"MembershipPath`""
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

# Initialize mutex for thread-safe file writing
$mutex = [System.Threading.Mutex]::new($false, "EntraGroupsCSVMutex")

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Initialize group cache
    $script:groupCache = @{}
    
    # Initialize batch processing
    $batchSize = $config.EntraID.BatchSize
    $totalProcessed = 0
    $batchNumber = 0
    
    #$nextLink = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName&`$top=$batchSize"
    $nextLink = Get-InitialUserQuery -Config $config.EntraID -SelectFields "id,userPrincipalName" -BatchSize $batchSize

    Write-Host "Starting user group membership collection..."
    
    while ($nextLink) {
        $batchNumber++
        Write-Host "Processing batch $batchNumber..."
        
        # Check memory
        if (Test-MemoryPressure -ThresholdGB $config.EntraID.MemoryThresholdGB `
                                -WarningGB $config.EntraID.MemoryWarningThresholdGB) {
            # Clear cache if needed
            if ($script:groupCache.Count -gt 1000) {
                $script:groupCache.Clear()
            }
        }
        
        # Get batch
        $batchData = Get-GraphBatch -NextLink $nextLink -Config $config.EntraID
        $users = $batchData.Items
        $nextLink = $batchData.NextLink
        
        if ($users.Count -gt 0) {
            # Process users in parallel
            $batchResults = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            
            $users | ForEach-Object -ThrottleLimit $config.EntraID.ParallelThrottle -Parallel {
                # Import module in parallel scope
                Import-Module "D:\ID-Tool\Modules\Entra.Functions.psm1" -Force
                
                $user = $_
                $localBatchResults = $using:batchResults
                $localConfig = $using:config
                $localGroupCache = $using:groupCache
                $errorValue = ""
                
                try {
                    $userIdentifier = ($user.userPrincipalName -split '@')[0]
                    
                    # Get user's direct group memberships
                    $directGroups = Invoke-GraphWithRetry `
                        -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)/memberOf" `
                        -Config $localConfig.EntraID
                    
                    # Get group IDs for direct memberships
                    $directGroupIds = @($directGroups.value | 
                        Where-Object { $_.'@odata.type' -eq "#microsoft.graph.group" } | 
                        Select-Object -ExpandProperty id)
                    
                    # Get all group memberships (direct + transitive)
                    $userGroups = Invoke-GraphWithRetry `
                        -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)/transitiveMemberOf" `
                        -Config $localConfig.EntraID
                    
                    if (-not $userGroups.value -or $userGroups.value.Count -eq 0) {
                        # User has no groups
                        $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`",`"{4}`",`"{5}`",`"{6}`",`"{7}`"" -f `
                            $userIdentifier,
                            $user.userPrincipalName,
                            $errorValue,
                            $errorValue,
                            $errorValue,
                            $errorValue,
                            $errorValue,
                            $errorValue
                        $localBatchResults.Add($line)
                    }
                    else {
                        foreach ($group in $userGroups.value) {
                            if ($group.'@odata.type' -ne "#microsoft.graph.group") { continue }
                            
                            # Determine if direct or inherited
                            $isDirectMember = $directGroupIds -contains $group.id
                            $membershipPath = if ($isDirectMember) { "Direct" } else { "Inherited" }
                            
                            # Get group info from cache or API
                            if (-not $localGroupCache.ContainsKey($group.id)) {
                                # Determine group type
                                $groupType = if ($group.groupTypes.Count -eq 0) {
                                    if (-not $group.mailEnabled -and $group.securityEnabled) {
                                        "Security"
                                    }
                                    elseif ($group.mailEnabled -and $group.securityEnabled) {
                                        "Mail-enabled Security"
                                    }
                                    elseif ($group.mailEnabled -and -not $group.securityEnabled) {
                                        "Distribution"
                                    }
                                    else {
                                        $errorValue
                                    }
                                }
                                else {
                                    "Microsoft 365"
                                }
                                                                
                                $localGroupCache[$group.id] = @{
                                    DisplayName = $group.displayName
                                    IsAssignableToRole = if ($null -eq $group.isAssignableToRole) { "0" } else { if ($group.isAssignableToRole) { "1" } else { "0" } }
                                    SecurityEnabled = if ($null -ne $group.securityEnabled) { if ($group.securityEnabled) { "1" } else { "0" } } else { "" }
                                    Type = $groupType
                                    MembershipType = if ($group.membershipRule) { "Dynamic" } else { "Assigned" }
                                }
                         }
                            
                            $groupInfo = $localGroupCache[$group.id]
                            
                            # Format CSV line with membership path
                            $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`",`"{4}`",`"{5}`",`"{6}`",`"{7}`"" -f `
                                $userIdentifier,
                                $user.userPrincipalName,
                                $groupInfo.DisplayName,
                                $groupInfo.IsAssignableToRole,
                                $groupInfo.Type,
                                $groupInfo.MembershipType,
                                $groupInfo.SecurityEnabled,
                                $membershipPath
                            
                            $localBatchResults.Add($line)
                        }
                    }
                }
                catch {
                    Write-Warning "Error processing user $($user.userPrincipalName): $_"
                }
            }
            
            # Write batch to file (thread-safe)
            if ($batchResults.Count -gt 0) {
                try {
                    $mutex.WaitOne() | Out-Null
                    $batchResults | Add-Content -Path $tempPath -Encoding UTF8
                }
                finally {
                    $mutex.ReleaseMutex()
                }
                
                $totalProcessed += $users.Count
                Write-Host "Completed batch $batchNumber. Total users processed: $totalProcessed"
            }
        }
    }
    
    Write-Host "Processing complete. Total users processed: $totalProcessed"
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "$($config.FilePrefixes.EntraGroups)_$timestamp.csv" -Config $config
}
catch {
    Write-Error "Error collecting Entra groups: $_"
    throw
}
finally {
    if ($mutex) { 
        $mutex.Dispose() 
    }
    if ($script:groupCache) {
        $script:groupCache.Clear()
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}
