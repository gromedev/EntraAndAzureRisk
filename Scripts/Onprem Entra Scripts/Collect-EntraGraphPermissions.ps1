#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Entra ID user Graph API permissions with hybrid bulk/per-user processing
#>

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
$tempPath = Join-Path $config.Paths.Temp "$($config.FilePrefixes.EntraGraphPermissions)_$timestamp.csv"

# Initialize CSV
$csvHeader = '"UserIdentifier","UserPrincipalName","PermissionType","Permission","ClientAppID","AppName"'
Set-Content -Path $tempPath -Value $csvHeader -Encoding UTF8

try {
    # Connect to Graph
    Connect-ToGraph -Config $config.EntraID
    
    # Initialize processing variables
    $resultBuffer = [System.Collections.Generic.List[string]]::new()
    $totalProcessed = 0
    $permissionsFound = 0
    
    # STEP 1: Build delegated permissions lookup table from OAuth2 grants (bulk)
    Write-Host "Building delegated permissions lookup table..."
    $userDelegatedPermissions = @{}  # userId -> array of delegated permissions
    $spCache = @{}  # Service principal cache
    $clientAppCache = @{}  # Client app cache
    
    # Get all OAuth2 permission grants (delegated permissions) in bulk
    Write-Host "Collecting all OAuth2 permission grants..."
    try {
        $oauth2Grants = Invoke-GraphRequestWithPaging `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            -Config $config.EntraID
        
        Write-Host "Found $($oauth2Grants.Count) OAuth2 permission grants"
        
        foreach ($grant in $oauth2Grants) {
            if ($grant.principalId -and $grant.scope) {
                # Get service principal info for resource (API being accessed)
                if ($grant.resourceId -and -not $spCache.ContainsKey($grant.resourceId)) {
                    try {
                        $sp = Invoke-GraphWithRetry `
                            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($grant.resourceId)" `
                            -Config $config.EntraID
                        
                        $spCache[$grant.resourceId] = @{
                            AppId = $sp.appId
                            DisplayName = $sp.displayName
                        }
                        
                        if ($sp.appId) {
                            $clientAppCache[$sp.appId] = $sp.displayName
                        }
                    }
                    catch {
                        # Cache miss
                    }
                }
                
                $resourceInfo = $spCache[$grant.resourceId]
                
                # Process each scope
                foreach ($scope in ($grant.scope -split ' ')) {
                    if ([string]::IsNullOrWhiteSpace($scope)) { continue }
                    
                    if (-not $userDelegatedPermissions.ContainsKey($grant.principalId)) {
                        $userDelegatedPermissions[$grant.principalId] = @()
                    }
                    
                    # Fixed field mapping per original script
                    $userDelegatedPermissions[$grant.principalId] += @{
                        PermissionType = "Delegated"
                        Permission = $scope
                        ResourceId = $grant.clientId  # ResourceId is actually clientId per IdentityTool
                        ClientAppId = if ($resourceInfo) { $resourceInfo.DisplayName } else { "" }
                    }
                }
            }
        }
        
        # Clean up OAuth2 grants
        $oauth2Grants = $null
        [System.GC]::Collect()
        
    } catch {
        Write-Warning "Error collecting OAuth2 permission grants: $_"
    }
    
    Write-Host "Delegated permissions lookup table built with $($userDelegatedPermissions.Count) users"
    
    # STEP 2: Process users in batches and get app role assignments per batch (hybrid approach)
    Write-Host "Processing users in batches..."
    $batchSize = $config.EntraID.BatchSize
    $batchNumber = 0
    
    if ($TestUser) {
        $nextLink = "https://graph.microsoft.com/v1.0/users?`$filter=startsWith(userPrincipalName,'$TestUser')&`$select=id,userPrincipalName&`$top=$batchSize"
        Write-Host "Testing with user: $TestUser"
    } else {
        $nextLink = Get-InitialUserQuery -Config $config.EntraID -SelectFields "id,userPrincipalName" -BatchSize $batchSize
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
            
            # Clear caches if too large
            if ($spCache.Count -gt 10000) {
                $spCache.Clear()
            }
            if ($clientAppCache.Count -gt 10000) {
                $clientAppCache.Clear()
            }
        }
        
        # Get batch
        $batchData = Get-GraphBatch -NextLink $nextLink -Config $config.EntraID
        $users = $batchData.Items
        $nextLink = $batchData.NextLink
        
        if ($users.Count -gt 0) {
            foreach ($user in $users) {
                $userIdentifier = ($user.userPrincipalName -split '@')[0]
                $userHasPermissions = $false
                
                # DELEGATED PERMISSIONS: Look up from bulk table
                if ($userDelegatedPermissions.ContainsKey($user.id)) {
                    foreach ($permission in $userDelegatedPermissions[$user.id]) {
                        $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f `
                            $userIdentifier,
                            $user.userPrincipalName,
                            $permission.PermissionType,
                            $permission.Permission,
                            $permission.ResourceId,
                            $permission.ClientAppId
                        
                        $resultBuffer.Add($line)
                        $permissionsFound++
                        $userHasPermissions = $true
                    }
                }
                
                # APPLICATION PERMISSIONS: Get per user (can't bulk these)
                try {
                    $appRoleAssignments = Invoke-GraphWithRetry `
                        -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)/appRoleAssignments" `
                        -Config $config.EntraID
                    
                    foreach ($assignment in $appRoleAssignments.value) {
                        # Get service principal info
                        if ($assignment.resourceId -and -not $spCache.ContainsKey($assignment.resourceId)) {
                            try {
                                $sp = Invoke-GraphWithRetry `
                                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($assignment.resourceId)" `
                                    -Config $config.EntraID
                                
                                $spCache[$assignment.resourceId] = @{
                                    AppRoles = $sp.appRoles
                                    DisplayName = $sp.displayName
                                    AppId = $sp.appId
                                }
                            }
                            catch {
                                # Cache miss
                            }
                        }
                        
                        $spInfo = $spCache[$assignment.resourceId]
                        
                        if ($spInfo) {
                            $appRole = $spInfo.AppRoles | Where-Object { $_.Id -eq $assignment.appRoleId }
                            
                            if ($appRole) {
                                # Fixed field mapping per original script
                                $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f `
                                    $userIdentifier,
                                    $user.userPrincipalName,
                                    "Application",
                                    $appRole.Value,
                                    $assignment.resourceId,  # ResourceId field
                                    $spInfo.DisplayName      # ClientAppId field contains display name
                                
                                $resultBuffer.Add($line)
                                $permissionsFound++
                                $userHasPermissions = $true
                            }
                        }
                    }
                }
                catch {
                    # Error getting app role assignments for this user - continue
                }
                
                # If user has no permissions, add empty entry
                if (-not $userHasPermissions) {
                    $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f `
                        $userIdentifier,
                        $user.userPrincipalName,
                        "",
                        "",
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
            
            Write-Host "Completed batch $batchNumber. Total users processed: $totalProcessed... Found $permissionsFound permissions"
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
    Write-Host "Total permissions found: $permissionsFound" -ForegroundColor Cyan
    
    # Move to final location
    Move-ProcessedCSV -SourcePath $tempPath -FinalFileName "$($config.FilePrefixes.EntraGraphPermissions)_$timestamp.csv" -Config $config

} catch {
    Write-Error "Error collecting Graph permissions: $_"
    throw
} finally {
    # Clean up - original pattern
    if ($resultBuffer) { 
        $resultBuffer.Clear()
        $resultBuffer = $null
    }
    if ($userDelegatedPermissions) {
        $userDelegatedPermissions.Clear()
        $userDelegatedPermissions = $null
    }
    if ($spCache) {
        $spCache.Clear()
        $spCache = $null
    }
    if ($clientAppCache) {
        $clientAppCache.Clear()
        $clientAppCache = $null
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    [System.GC]::Collect()
}
