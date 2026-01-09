<#
.SYNOPSIS
    Creates test data with dangerous permissions for testing DeriveEdges
.DESCRIPTION
    Creates service principals with dangerous Graph permissions and users with
    privileged directory roles to test abuse edge derivation.

    THIS IS FOR TEST TENANTS ONLY - creates actual vulnerabilities!
#>

#Requires -Version 7.0
[CmdletBinding()]
param()

# Microsoft Graph Service Principal ID (well-known across all tenants)
$MSGraphAppId = "00000003-0000-0000-c000-000000000000"

# Dangerous Graph Permissions (from DangerousPermissions.psd1)
$DangerousGraphPermissions = @{
    # Application.ReadWrite.All - can modify any app
    "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9" = "Application.ReadWrite.All"
    # AppRoleAssignment.ReadWrite.All - can grant any permission
    "06b708a9-e830-4db3-a914-8e69da51d44f" = "AppRoleAssignment.ReadWrite.All"
    # RoleManagement.ReadWrite.Directory - can assign directory roles
    "9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8" = "RoleManagement.ReadWrite.Directory"
}

# Dangerous Directory Roles (from DangerousPermissions.psd1)
$DangerousDirectoryRoles = @{
    "62e90394-69f5-4237-9190-012177145e10" = "Global Administrator"
    "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3" = "Application Administrator"
    "158c047a-c907-4556-b7ef-446551a6b5f7" = "Cloud Application Administrator"
}

function Connect-ToGraph {
    $context = Get-MgContext
    if (-not $context) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes @(
            'Application.ReadWrite.All',
            'AppRoleAssignment.ReadWrite.All',
            'RoleManagement.ReadWrite.Directory',
            'User.ReadWrite.All'
        ) -NoWelcome
    }
    return Get-MgContext
}

function Get-MSGraphServicePrincipal {
    Write-Host "Finding Microsoft Graph service principal..." -ForegroundColor Gray
    $filter = "appId eq '$MSGraphAppId'"
    $result = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter"
    if ($result.value.Count -eq 0) {
        throw "Microsoft Graph service principal not found!"
    }
    return $result.value[0]
}

function New-DangerousApp {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "DeriveEdges-Test-App-$id"

    Write-Host "Creating test application: $name" -ForegroundColor Yellow

    # Create application
    $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body @{
        displayName    = $name
        signInAudience = 'AzureADMyOrg'
    }

    # Create service principal
    $sp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{
        appId = $app.appId
    }

    Write-Host "  + Created: $name (SP ID: $($sp.id))" -ForegroundColor Green
    return @{
        appId = $app.id
        appAppId = $app.appId
        spId = $sp.id
        displayName = $name
    }
}

function Add-DangerousGraphPermission {
    param(
        [string]$ServicePrincipalId,
        [string]$AppRoleId,
        [string]$PermissionName,
        [string]$MSGraphSpId
    )

    Write-Host "Granting dangerous permission: $PermissionName" -ForegroundColor Yellow

    try {
        $result = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalId/appRoleAssignments" -Body @{
            principalId = $ServicePrincipalId
            resourceId = $MSGraphSpId
            appRoleId = $AppRoleId
        }
        Write-Host "  + Granted: $PermissionName (appRoleId: $AppRoleId)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "  ! Failed to grant $PermissionName`: $_"
        return $false
    }
}

function Add-DangerousDirectoryRole {
    param(
        [string]$PrincipalId,
        [string]$RoleTemplateId,
        [string]$RoleName
    )

    Write-Host "Assigning dangerous role: $RoleName" -ForegroundColor Yellow

    try {
        $result = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' -Body @{
            principalId      = $PrincipalId
            roleDefinitionId = $RoleTemplateId
            directoryScopeId = '/'
        }
        Write-Host "  + Assigned: $RoleName (roleTemplateId: $RoleTemplateId)" -ForegroundColor Green
        return $result.id
    }
    catch {
        if ($_.Exception.Message -match 'already exists') {
            Write-Host "  = Role already assigned" -ForegroundColor Gray
            return "exists"
        }
        Write-Warning "  ! Failed to assign $RoleName`: $_"
        return $null
    }
}

function New-DangerousUser {
    param([string]$Domain)

    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "DeriveEdges-Test-User-$id"
    $upn = "deriveedges-test-$id@$Domain".ToLower()

    Write-Host "Creating test user: $name" -ForegroundColor Yellow

    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%'
    $password = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

    try {
        $user = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' -Body @{
            displayName       = $name
            userPrincipalName = $upn
            mailNickname      = "deriveedges-test-$id"
            accountEnabled    = $true
            passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $true }
        }
        Write-Host "  + Created: $name" -ForegroundColor Green
        return @{ id = $user.id; displayName = $name; upn = $upn }
    }
    catch {
        Write-Warning "  ! Failed to create user: $_"
        return $null
    }
}

# Main execution
try {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host " DeriveEdges Test Data Creator" -ForegroundColor White
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host " WARNING: This creates actual vulnerabilities!" -ForegroundColor Red
    Write-Host " Only run in TEST tenants!" -ForegroundColor Red
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host ""

    # Connect
    $context = Connect-ToGraph

    # Get tenant domain
    $org = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization'
    $domain = ($org.value[0].verifiedDomains | Where-Object { $_.isDefault }).name
    Write-Host "Tenant: $domain" -ForegroundColor Cyan
    Write-Host ""

    # Get MS Graph SP
    $msGraphSp = Get-MSGraphServicePrincipal
    Write-Host "MS Graph SP ID: $($msGraphSp.id)" -ForegroundColor Gray
    Write-Host ""

    #region 1. Create App with Dangerous Permissions
    Write-Host "=== PHASE 1: Dangerous Graph Permissions ===" -ForegroundColor White

    $dangerousApp = New-DangerousApp

    # Grant each dangerous permission
    foreach ($permId in $DangerousGraphPermissions.Keys) {
        $permName = $DangerousGraphPermissions[$permId]
        Add-DangerousGraphPermission -ServicePrincipalId $dangerousApp.spId `
                                     -AppRoleId $permId `
                                     -PermissionName $permName `
                                     -MSGraphSpId $msGraphSp.id | Out-Null
    }
    Write-Host ""
    #endregion

    #region 2. Create User with Dangerous Directory Role
    Write-Host "=== PHASE 2: Dangerous Directory Roles ===" -ForegroundColor White

    $dangerousUser = New-DangerousUser -Domain $domain

    if ($dangerousUser) {
        # Assign Application Administrator role (less destructive than Global Admin)
        $appAdminRoleId = "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"
        Add-DangerousDirectoryRole -PrincipalId $dangerousUser.id `
                                   -RoleTemplateId $appAdminRoleId `
                                   -RoleName "Application Administrator" | Out-Null
    }
    Write-Host ""
    #endregion

    #region 3. Summary
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host " SUMMARY" -ForegroundColor White
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Created test data that DeriveEdges should detect:" -ForegroundColor Green
    Write-Host ""
    Write-Host "1. App with Dangerous Graph Permissions:" -ForegroundColor Cyan
    Write-Host "   - App: $($dangerousApp.displayName)" -ForegroundColor Gray
    Write-Host "   - SP ID: $($dangerousApp.spId)" -ForegroundColor Gray
    Write-Host "   - Permissions: $($DangerousGraphPermissions.Values -join ', ')" -ForegroundColor Gray
    Write-Host ""
    if ($dangerousUser) {
        Write-Host "2. User with Dangerous Directory Role:" -ForegroundColor Cyan
        Write-Host "   - User: $($dangerousUser.displayName)" -ForegroundColor Gray
        Write-Host "   - User ID: $($dangerousUser.id)" -ForegroundColor Gray
        Write-Host "   - Role: Application Administrator" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Run the orchestrator to collect this data" -ForegroundColor Gray
    Write-Host "  2. Check Dashboard for derived edges" -ForegroundColor Gray
    Write-Host ""
    #endregion
}
catch {
    Write-Error "Error: $_"
    exit 1
}
