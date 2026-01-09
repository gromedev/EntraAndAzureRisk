#Requires -Version 7.0
<#
.SYNOPSIS
   Collects Entra ID role assignments including PIM eligible roles - SIMPLIFIED VERSION
.DESCRIPTION
   Follows original script pattern: batch users → get roles → write results
#>
function CollectEntraRoles {
 

[CmdletBinding()]
param(
    [string]$TestUser = $null  # Optional: specify a user to test with
)
# Import modules
Import-Module (Join-Path $PSScriptRoot "..\..\Modules\Entra.Functions.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\Modules\Common.Functions.psm1") -Force

# Get configuration
$config = Get-Config -ConfigPath (Join-Path $PSScriptRoot "..\..\Modules\giam-config.json") -Force -Verbose
Initialize-DataPaths -Config $config

# Setup paths
$timestamp = Get-Date -Format $config.FileManagement.DateFormat
$tempPath = Join-Path $config.Paths.Temp "$($config.FilePrefixes.EntraPermissions)_$timestamp.csv"

# Initialize CSV with IdentityTool headers (exact match)
$csvHeader = "`"UserIdentifier`",`"UserPrincipalName`",`"Role`",`"PIM`""
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Get security group members for role assignments
    $securityGroupMembers = Get-SecurityGroupMembers -Config $config.EntraID
    
    # Initialize processing variables
    $resultBuffer = [System.Collections.Generic.List[string]]::new()
    $totalProcessed = 0
    $rolesFound = 0
    
    # STEP 1: Build role lookup table from bulk collections
    Write-Host "Building role lookup table..."
    $userRoles = @{}  # userId -> array of role assignments
    
    # Get all ACTIVE role assignments in bulk
    Write-Host "Collecting all active role assignments..."
    try {
        $activeAssignments = Invoke-GraphRequestWithPaging `
            -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignmentScheduleInstances?`$expand=principal,roleDefinition&`$select=principalId,assignmentType,principal,roleDefinition" `
            -Config $config.EntraID
        
        Write-Host "Found $($activeAssignments.Count) active role assignments"
        
        foreach ($assignment in $activeAssignments) {
            # Determine assignment type - FIXED LOGIC
            $assignmentType = if ($assignment.assignmentType -eq "Assigned") {
                "Permanent"
            } else {
                "PIM"
            }
            
            # Process user assignments
            if ($assignment.principal.'@odata.type' -eq '#microsoft.graph.user') {
                $userId = $assignment.principal.id
                
                if (-not $userRoles.ContainsKey($userId)) {
                    $userRoles[$userId] = @()
                }
                
                $userRoles[$userId] += @{
                    RoleName = $assignment.roleDefinition.displayName
                    AssignmentType = $assignmentType
                    UserPrincipalName = $assignment.principal.userPrincipalName
                    UserIdentifier = ($assignment.principal.userPrincipalName -split '@')[0]
                }
            }
            # Process group assignments
            elseif ($assignment.principal.'@odata.type' -eq '#microsoft.graph.group' -and
                    $securityGroupMembers.ContainsKey($assignment.principal.id)) {
                
                $groupInfo = $securityGroupMembers[$assignment.principal.id]
                $groupAssignmentType = "Group-$assignmentType ($($groupInfo.GroupDisplayName))"
                
                foreach ($member in $groupInfo.Members) {
                    if ($member.Type -eq "User" -and $member.UserPrincipalName) {
                        # We don't have userId for group members, so we'll handle these during user processing
                        # Store group-based roles separately for now
                        $memberKey = $member.UserPrincipalName.ToLower()
                        
                        if (-not $userRoles.ContainsKey($memberKey)) {
                            $userRoles[$memberKey] = @()
                        }
                        
                        $userRoles[$memberKey] += @{
                            RoleName = $assignment.roleDefinition.displayName
                            AssignmentType = $groupAssignmentType
                            UserPrincipalName = $member.UserPrincipalName
                            UserIdentifier = ($member.UserPrincipalName -split '@')[0]
                            IsGroupBased = $true
                        }
                    }
                }
            }
        }
        
        # Clean up active assignments
        $activeAssignments = $null
        [System.GC]::Collect()
        
    } catch {
        Write-Warning "Error collecting active role assignments: $_"
        Write-Host "This may be due to missing permissions or PIM not being available."
    }
    
    # Get all ELIGIBLE role assignments in bulk
    Write-Host "Collecting all eligible role assignments..."
    try {
        $eligibleAssignments = Invoke-GraphRequestWithPaging `
            -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleEligibilityScheduleInstances?`$expand=principal,roleDefinition&`$select=principalId,principal,roleDefinition" `
            -Config $config.EntraID
        
        Write-Host "Found $($eligibleAssignments.Count) eligible role assignments"
        
        foreach ($assignment in $eligibleAssignments) {
            # Process user assignments
            if ($assignment.principal.'@odata.type' -eq '#microsoft.graph.user') {
                $userId = $assignment.principal.id
                
                if (-not $userRoles.ContainsKey($userId)) {
                    $userRoles[$userId] = @()
                }
                
                $userRoles[$userId] += @{
                    RoleName = $assignment.roleDefinition.displayName
                    AssignmentType = "PIM"
                    UserPrincipalName = $assignment.principal.userPrincipalName
                    UserIdentifier = ($assignment.principal.userPrincipalName -split '@')[0]
                }
            }
            # Process group assignments
            elseif ($assignment.principal.'@odata.type' -eq '#microsoft.graph.group' -and
                    $securityGroupMembers.ContainsKey($assignment.principal.id)) {
                
                $groupInfo = $securityGroupMembers[$assignment.principal.id]
                $groupAssignmentType = "Group-PIM ($($groupInfo.GroupDisplayName))"
                
                foreach ($member in $groupInfo.Members) {
                    if ($member.Type -eq "User" -and $member.UserPrincipalName) {
                        $memberKey = $member.UserPrincipalName.ToLower()
                        
                        if (-not $userRoles.ContainsKey($memberKey)) {
                            $userRoles[$memberKey] = @()
                        }
                        
                        $userRoles[$memberKey] += @{
                            RoleName = $assignment.roleDefinition.displayName
                            AssignmentType = $groupAssignmentType
                            UserPrincipalName = $member.UserPrincipalName
                            UserIdentifier = ($member.UserPrincipalName -split '@')[0]
                            IsGroupBased = $true
                        }
                    }
                }
            }
        }
        
        # Clean up eligible assignments
        $eligibleAssignments = $null
        [System.GC]::Collect()
        
    } catch {
        Write-Warning "Error collecting eligible role assignments: $_"
        Write-Host "This may be due to missing Microsoft Entra ID Premium P2 license or permissions."
    }
    
    Write-Host "Role lookup table built with $($userRoles.Count) entries"
    
    # STEP 2: Process users in batches using config batch size
    Write-Host "Processing users in batches..."
    $batchSize = $config.EntraID.BatchSize
    $batchNumber = 0
    
    if ($TestUser) {
        $nextLink = "https://graph.microsoft.com/v1.0/users?`$filter=startsWith(userPrincipalName,'$TestUser')&`$select=id,userPrincipalName,displayName,accountEnabled&`$top=$batchSize"
        Write-Host "Testing with user: $TestUser"
    } else {
        $nextLink = Get-InitialUserQuery -Config $config.EntraID -SelectFields "id,userPrincipalName,displayName,accountEnabled" -BatchSize $batchSize
    }
    
    while ($nextLink) {
        $batchNumber++
        Write-Host "Processing user batch $batchNumber..."
        
        # Check memory - original pattern
        if (Test-MemoryPressure -ThresholdGB $config.EntraID.MemoryThresholdGB `
                                -WarningGB $config.EntraID.MemoryWarningThresholdGB) {
            if ($resultBuffer.Count -gt 0) {
                Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
            }
        }
        
        # Get batch
        $batchData = Get-GraphBatch -NextLink $nextLink -Config $config.EntraID
        $users = $batchData.Items
        $nextLink = $batchData.NextLink
        
        if ($users.Count -gt 0) {
            foreach ($user in $users) {
                $userIdentifier = ($user.userPrincipalName -split '@')[0]
                $userHasRoles = $false
                
                # Look up roles for this user (by userId first, then by UPN for group-based roles)
                $userRoleList = @()
                
                # Check direct user roles (by userId)
                if ($userRoles.ContainsKey($user.id)) {
                    $userRoleList += $userRoles[$user.id]
                }
                
                # Check group-based roles (by UPN)
                $upnKey = $user.userPrincipalName.ToLower()
                if ($userRoles.ContainsKey($upnKey)) {
                    $userRoleList += $userRoles[$upnKey]
                }
                
                # Write role assignments for this user
                if ($userRoleList.Count -gt 0) {
                    foreach ($role in $userRoleList) {
                        $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`"" -f `
                            $userIdentifier,
                            $user.userPrincipalName,
                            $role.RoleName,
                            $role.AssignmentType
                        $resultBuffer.Add($line)
                        $rolesFound++
                        $userHasRoles = $true
                    }
                }
                
                # If user has no roles, add empty entry
                if (-not $userHasRoles) {
                    $line = "`"{0}`",`"{1}`",`"{2}`",`"{3}`"" -f `
                        $userIdentifier,
                        $user.userPrincipalName,
                        "",
                        ""
                    $resultBuffer.Add($line)
                }
                
                $totalProcessed++
                
                # Write buffer when full - original pattern
                if ($resultBuffer.Count -ge $config.ActiveDirectory.BufferLimit) {
                    Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
                }
            }
            
            Write-Host "Completed batch $batchNumber. Total users processed: $totalProcessed... Found $rolesFound roles"
        }
        
        # Clear batch data
        $users = $null
        $batchData = $null
    }
    
    # Write remaining buffer
    if ($resultBuffer.Count -gt 0) {
        Write-BufferToFile -Buffer $resultBuffer -FilePath $tempPath
    }
    
    Write-Host "Processing complete!" -ForegroundColor Green
    Write-Host "Total users processed: $totalProcessed" -ForegroundColor Cyan
    Write-Host "Total role assignments found: $rolesFound" -ForegroundColor Cyan
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "$($config.FilePrefixes.EntraPermissions)_$timestamp.csv" -Config $config

} catch {
    Write-Error "Error collecting Entra permissions: $_"
    throw
} finally {
    # Clean up - original pattern
    if ($resultBuffer) { 
        $resultBuffer.Clear()
        $resultBuffer = $null
    }
    if ($userRoles) {
        $userRoles.Clear()
        $userRoles = $null
    }
    if ($securityGroupMembers) {
        $securityGroupMembers.Clear()
        $securityGroupMembers = $null
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}
}

CollectEntraRoles #-TestUser "adminWPKV@novonordisk.com"
