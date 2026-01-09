# Update-GraphApiPermissions.ps1
# Downloads Microsoft Graph API permission data and generates GraphApiPermissions.psd1
# Source: Microsoft Graph DevX Content repository

<#
.SYNOPSIS
    Updates the GraphApiPermissions.psd1 file with latest Microsoft Graph permission data.

.DESCRIPTION
    Downloads the permissions.json file from Microsoft's Graph DevX Content repository,
    parses it, and generates a PowerShell data file (.psd1) for use in permission analysis.

.PARAMETER OutputPath
    Path where GraphApiPermissions.psd1 will be written.
    Default: ../FunctionApp/Modules/EntraDataCollection/GraphApiPermissions.psd1

.EXAMPLE
    .\Update-GraphApiPermissions.ps1

.EXAMPLE
    .\Update-GraphApiPermissions.ps1 -OutputPath "C:\temp\GraphApiPermissions.psd1"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\FunctionApp\Modules\EntraDataCollection\GraphApiPermissions.psd1")
)

$ErrorActionPreference = 'Stop'

# Microsoft's official permissions data source
$PermissionsUrl = "https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/refs/heads/master/permissions/new/permissions.json"

Write-Host "Downloading permissions data from Microsoft Graph DevX Content..." -ForegroundColor Cyan

try {
    $response = Invoke-WebRequest -Uri $PermissionsUrl -UseBasicParsing
    $permissionsData = $response.Content | ConvertFrom-Json -AsHashtable
    Write-Host "Downloaded $($permissionsData.Count) permission entries" -ForegroundColor Green
}
catch {
    Write-Error "Failed to download permissions data: $_"
    return
}

# Initialize data structures
$endpointIndex = @{}      # Path -> Method -> Scheme -> Permissions
$permissionMetadata = @{} # Permission name -> metadata
$permissionToEndpoints = @{} # Permission name -> array of endpoints it grants access to

Write-Host "Parsing permission data..." -ForegroundColor Cyan

$totalPaths = 0
$totalPermissions = $permissionsData.Count

foreach ($permName in $permissionsData.Keys) {
    $perm = $permissionsData[$permName]

    # Store permission metadata
    $permissionMetadata[$permName] = @{
        Id = $perm.id
        DisplayName = if ($perm.displayName) { $perm.displayName } else { $permName }
        Description = $perm.description
        IsAdmin = $perm.isAdmin -eq $true
        IsHidden = $perm.isHidden -eq $true
        IsDevXHidden = $perm.isDevxHidden -eq $true
        ConsentType = $perm.consentType
        GrantType = $perm.grantType
    }

    # Initialize endpoint list for this permission
    if (-not $permissionToEndpoints.ContainsKey($permName)) {
        $permissionToEndpoints[$permName] = [System.Collections.Generic.List[string]]::new()
    }

    # Process pathSets (contains endpoint/method/scheme mappings)
    if ($perm.pathSets) {
        foreach ($pathSet in $perm.pathSets) {
            # pathSet has: schemeKeys, methods, paths
            $schemes = $pathSet.schemeKeys
            $methods = $pathSet.methods

            # Check for least privilege indicator
            $leastPrivilegeSchemes = @()
            foreach ($pathEntry in $pathSet.paths) {
                $pathValue = $pathEntry

                # Extract least= metadata if present
                if ($pathValue -match 'least=([^,\s]+(?:,[^,\s]+)*)') {
                    $leastPrivilegeSchemes = $Matches[1] -split ','
                }

                # Normalize path (remove metadata, lowercase)
                $normalizedPath = ($pathValue -replace '\s*least=[^\s]*\s*', '' -replace '\s*alsoRequires=[^\s]*\s*', '').Trim().ToLower()

                if ([string]::IsNullOrWhiteSpace($normalizedPath)) { continue }

                $totalPaths++

                # Track which endpoints this permission grants access to
                $permissionToEndpoints[$permName].Add($normalizedPath)

                # Initialize endpoint entry if not exists
                if (-not $endpointIndex.ContainsKey($normalizedPath)) {
                    $endpointIndex[$normalizedPath] = @{}
                }

                # Process each method
                foreach ($method in $methods) {
                    if (-not $endpointIndex[$normalizedPath].ContainsKey($method)) {
                        $endpointIndex[$normalizedPath][$method] = @{
                            Application = [System.Collections.Generic.List[string]]::new()
                            DelegatedWork = [System.Collections.Generic.List[string]]::new()
                            DelegatedPersonal = [System.Collections.Generic.List[string]]::new()
                            LeastPrivilege = @{
                                Application = $null
                                DelegatedWork = $null
                                DelegatedPersonal = $null
                            }
                        }
                    }

                    # Add permission to each scheme it supports
                    foreach ($scheme in $schemes) {
                        $schemeKey = switch ($scheme) {
                            "DelegatedWork" { "DelegatedWork" }
                            "DelegatedPersonal" { "DelegatedPersonal" }
                            "Application" { "Application" }
                            default { $scheme }
                        }

                        if ($endpointIndex[$normalizedPath][$method].ContainsKey($schemeKey)) {
                            $currentList = $endpointIndex[$normalizedPath][$method][$schemeKey]
                            if ($currentList -is [System.Collections.Generic.List[string]] -and -not $currentList.Contains($permName)) {
                                $currentList.Add($permName)
                            }

                            # Mark as least privilege if indicated
                            if ($leastPrivilegeSchemes -contains $scheme) {
                                $endpointIndex[$normalizedPath][$method].LeastPrivilege[$schemeKey] = $permName
                            }
                        }
                    }
                }
            }
        }
    }
}

Write-Host "Processed $totalPermissions permissions across $($endpointIndex.Count) unique endpoints" -ForegroundColor Green

# Convert lists to arrays for .psd1 format
Write-Host "Converting to PowerShell data format..." -ForegroundColor Cyan

function ConvertTo-PsdString {
    param($Value, $Indent = 0)

    $indentStr = "    " * $Indent

    if ($null -eq $Value) {
        return "`$null"
    }
    elseif ($Value -is [bool]) {
        return if ($Value) { "`$true" } else { "`$false" }
    }
    elseif ($Value -is [string]) {
        # Escape single quotes
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }
    elseif ($Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) {
            return "@()"
        }
        $items = $Value | ForEach-Object { ConvertTo-PsdString $_ ($Indent + 1) }
        return "@(" + ($items -join ", ") + ")"
    }
    elseif ($Value -is [hashtable] -or $Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) {
            return "@{}"
        }
        $lines = @("@{")
        foreach ($key in $Value.Keys | Sort-Object) {
            $keyStr = if ($key -match '^[a-zA-Z_][a-zA-Z0-9_]*$') { $key } else { "'$key'" }
            $valStr = ConvertTo-PsdString $Value[$key] ($Indent + 1)
            $lines += "$indentStr    $keyStr = $valStr"
        }
        $lines += "$indentStr}"
        return $lines -join "`n"
    }
    else {
        return $Value.ToString()
    }
}

# Build the final data structure
$finalData = @{
    LastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    SourceUrl = $PermissionsUrl
    TotalPermissions = $totalPermissions
    TotalEndpoints = $endpointIndex.Count

    # Permission metadata indexed by name
    Permissions = @{}

    # Endpoints indexed by path
    Endpoints = @{}

    # Reverse lookup: permission -> endpoints
    PermissionEndpoints = @{}
}

# Add permission metadata (top 500 most common to keep file size manageable)
foreach ($permName in $permissionMetadata.Keys) {
    $finalData.Permissions[$permName] = $permissionMetadata[$permName]
}

# Add endpoint data
foreach ($path in $endpointIndex.Keys) {
    $pathData = @{}
    foreach ($method in $endpointIndex[$path].Keys) {
        $methodData = $endpointIndex[$path][$method]
        $pathData[$method] = @{
            Application = @($methodData.Application | Sort-Object -Unique)
            DelegatedWork = @($methodData.DelegatedWork | Sort-Object -Unique)
            DelegatedPersonal = @($methodData.DelegatedPersonal | Sort-Object -Unique)
            LeastPrivilege = $methodData.LeastPrivilege
        }
    }
    $finalData.Endpoints[$path] = $pathData
}

# Add reverse lookup (permission -> endpoints) for the most relevant permissions
$relevantPermissions = $permissionMetadata.Keys | Where-Object {
    $permissionToEndpoints[$_].Count -gt 0
} | Sort-Object

foreach ($permName in $relevantPermissions) {
    $endpoints = $permissionToEndpoints[$permName] | Sort-Object -Unique
    $finalData.PermissionEndpoints[$permName] = @($endpoints)
}

# Generate the .psd1 content
Write-Host "Generating GraphApiPermissions.psd1..." -ForegroundColor Cyan

$psd1Content = @"
# GraphApiPermissions.psd1
# Microsoft Graph API Permission Reference Data
# Auto-generated by Update-GraphApiPermissions.ps1
# Last Updated: $($finalData.LastUpdated)
# Source: $($finalData.SourceUrl)
#
# Contains:
# - Permission metadata (ID, display name, admin consent required)
# - Endpoint to permission mappings (path -> method -> scheme -> permissions)
# - Least privilege recommendations per endpoint
# - Reverse lookup (permission -> endpoints it grants access to)

@{
    # Metadata
    LastUpdated = '$($finalData.LastUpdated)'
    SourceUrl = '$($finalData.SourceUrl)'
    TotalPermissions = $($finalData.TotalPermissions)
    TotalEndpoints = $($finalData.TotalEndpoints)

    # Permission metadata indexed by permission name
    # Structure: PermissionName -> @{ Id, DisplayName, Description, IsAdmin, ConsentType }
    Permissions = @{

"@

# Add permissions (limited to avoid huge file)
$permCount = 0
foreach ($permName in ($finalData.Permissions.Keys | Sort-Object)) {
    $perm = $finalData.Permissions[$permName]
    $escapedName = $permName -replace "'", "''"
    $escapedDisplay = if ($perm.DisplayName) { $perm.DisplayName -replace "'", "''" } else { "" }
    $escapedDesc = if ($perm.Description) { ($perm.Description -replace "'", "''" -replace "`n", " " -replace "`r", "").Substring(0, [Math]::Min(200, $perm.Description.Length)) } else { "" }

    $psd1Content += @"
        '$escapedName' = @{
            Id = '$($perm.Id)'
            DisplayName = '$escapedDisplay'
            Description = '$escapedDesc'
            IsAdmin = `$$($perm.IsAdmin.ToString().ToLower())
        }

"@
    $permCount++
}

$psd1Content += @"
    }

    # Endpoint index - maps API paths to required permissions
    # Structure: Path -> Method -> @{ Application, DelegatedWork, DelegatedPersonal, LeastPrivilege }
    # Note: Only top 1000 most common endpoints included to keep file manageable
    Endpoints = @{

"@

# Add endpoints (limited to 1000 to keep file size reasonable)
$endpointCount = 0
$maxEndpoints = 2000
foreach ($path in ($finalData.Endpoints.Keys | Sort-Object | Select-Object -First $maxEndpoints)) {
    $escapedPath = $path -replace "'", "''"
    $pathData = $finalData.Endpoints[$path]

    $psd1Content += "        '$escapedPath' = @{`n"

    foreach ($method in ($pathData.Keys | Sort-Object)) {
        $methodData = $pathData[$method]

        $appPerms = if ($methodData.Application.Count -gt 0) {
            "@('" + ($methodData.Application -join "', '") + "')"
        } else { "@()" }

        $delWorkPerms = if ($methodData.DelegatedWork.Count -gt 0) {
            "@('" + ($methodData.DelegatedWork -join "', '") + "')"
        } else { "@()" }

        $delPersonalPerms = if ($methodData.DelegatedPersonal.Count -gt 0) {
            "@('" + ($methodData.DelegatedPersonal -join "', '") + "')"
        } else { "@()" }

        $leastApp = if ($methodData.LeastPrivilege.Application) { "'$($methodData.LeastPrivilege.Application)'" } else { "`$null" }
        $leastDelWork = if ($methodData.LeastPrivilege.DelegatedWork) { "'$($methodData.LeastPrivilege.DelegatedWork)'" } else { "`$null" }
        $leastDelPersonal = if ($methodData.LeastPrivilege.DelegatedPersonal) { "'$($methodData.LeastPrivilege.DelegatedPersonal)'" } else { "`$null" }

        $psd1Content += @"
            $method = @{
                Application = $appPerms
                DelegatedWork = $delWorkPerms
                DelegatedPersonal = $delPersonalPerms
                LeastPrivilege = @{
                    Application = $leastApp
                    DelegatedWork = $leastDelWork
                    DelegatedPersonal = $leastDelPersonal
                }
            }

"@
    }

    $psd1Content += "        }`n`n"
    $endpointCount++
}

$psd1Content += @"
    }

    # Reverse lookup: Permission -> Endpoints it grants access to
    # Useful for analyzing what an app can access with a given permission
    PermissionEndpoints = @{

"@

# Add reverse lookup (limited to permissions with endpoints)
foreach ($permName in ($finalData.PermissionEndpoints.Keys | Sort-Object)) {
    $endpoints = $finalData.PermissionEndpoints[$permName]
    if ($endpoints.Count -eq 0) { continue }

    $escapedPermName = $permName -replace "'", "''"

    # Limit endpoints per permission to keep file size reasonable
    $limitedEndpoints = $endpoints | Select-Object -First 50
    $endpointList = "@('" + ($limitedEndpoints -join "', '") + "')"

    $psd1Content += "        '$escapedPermName' = $endpointList`n"
}

$psd1Content += @"
    }

    # Well-known resource IDs for API filtering
    WellKnownResourceIds = @{
        MicrosoftGraph = '00000003-0000-0000-c000-000000000000'
        AzureADGraph = '00000002-0000-0000-c000-000000000000'
        Office365Management = 'c5393580-f805-4401-95e8-94b7a6ef2fc2'
        AzureServiceManagement = '797f4846-ba00-4fd7-ba43-dac1f8f63013'
        AzureKeyVault = 'cfa8b339-82a2-471a-a3c9-0fc0be7a4093'
    }

    # Common high-privilege permissions that warrant attention
    HighPrivilegePermissions = @(
        'Application.ReadWrite.All'
        'AppRoleAssignment.ReadWrite.All'
        'Directory.ReadWrite.All'
        'RoleManagement.ReadWrite.Directory'
        'User.ReadWrite.All'
        'Group.ReadWrite.All'
        'Mail.ReadWrite'
        'Mail.Send'
        'Files.ReadWrite.All'
        'Sites.ReadWrite.All'
        'ServicePrincipalEndpoint.ReadWrite.All'
        'UserAuthenticationMethod.ReadWrite.All'
        'GroupMember.ReadWrite.All'
        'Device.ReadWrite.All'
    )
}
"@

# Write to file
$resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
Write-Host "Writing to: $resolvedPath" -ForegroundColor Cyan

# Ensure directory exists
$outputDir = Split-Path $resolvedPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($resolvedPath, $psd1Content, $utf8NoBom)

Write-Host "`nGraphApiPermissions.psd1 generated successfully!" -ForegroundColor Green
Write-Host "- Permissions: $permCount" -ForegroundColor White
Write-Host "- Endpoints: $endpointCount (limited from $($finalData.TotalEndpoints))" -ForegroundColor White
Write-Host "- File size: $([math]::Round((Get-Item $resolvedPath).Length / 1KB, 2)) KB" -ForegroundColor White
