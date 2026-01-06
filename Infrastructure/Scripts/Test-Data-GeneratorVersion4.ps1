#Requires -Version 7.0
# Requires -Modules Microsoft.Graph

<#
.SYNOPSIS
    Generates test data in an Entra ID tenant for testing data collection scripts
.DESCRIPTION
    This script creates a realistic test environment including:
    - Users with varied attributes, licenses, and sign-in states
    - Nested group hierarchies (security, Microsoft 365, dynamic)
    - Role assignments (direct, group-based, PIM-eligible)
    - Service principals with various permission levels
    - App registrations with delegated and application permissions
    - Windows Autopilot configuration with Group Tags (NEW in V4)

    Run this script multiple times (days apart) to generate historical data
    and test delta detection capabilities.
.PARAMETER TenantDomain
    Your test tenant domain (e.g., contoso.onmicrosoft.com)
.PARAMETER UserCount
    Number of test users to create (default: 50, max: 100 due to license limit)
.PARAMETER CreateNestedGroups
    Whether to create nested group hierarchies
.PARAMETER SetupAutopilot
    Whether to create Autopilot dynamic groups and deployment profiles
.PARAMETER AutopilotGroupTags
    Array of Autopilot group tags to create (default: @("Standard"))
.PARAMETER SimulateChanges
    If specified, modifies existing test data to simulate changes over time
.EXAMPLE
    .\Test-Data-GeneratorVersion4.ps1 -TenantDomain "contoso.onmicrosoft.com" -UserCount 50
.EXAMPLE
    .\Test-Data-GeneratorVersion4.ps1 -TenantDomain "gromedev01.onmicrosoft.com" -UserCount 50 -SetupAutopilot
.EXAMPLE
    .\Test-Data-GeneratorVersion4.ps1 -TenantDomain "gromedev01.onmicrosoft.com" -SetupAutopilot -AutopilotGroupTags @("Standard", "Kiosk", "Developer")
.EXAMPLE
    .\Test-Data-GeneratorVersion4.ps1 -TenantDomain "gromedev01.onmicrosoft.com" -SimulateChanges
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantDomain,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$UserCount = 50,

    [Parameter(Mandatory=$false)]
    [switch]$CreateNestedGroups,

    [Parameter(Mandatory=$false)]
    [switch]$SetupAutopilot,

    [Parameter(Mandatory=$false)]
    [string[]]$AutopilotGroupTags = @("Standard"),

    [Parameter(Mandatory=$false)]
    [string]$AutopilotGroupNamePrefix = "Autopilot-",

    [Parameter(Mandatory=$false)]
    [switch]$SimulateChanges
)

# Configuration
$script:Config = @{
    TestPrefix = "TestEntra"
    PasswordProfile = @{
        Password = "TestP@ssw0rd123!"
        ForceChangePasswordNextSignIn = $false
    }
    Departments = @("Engineering", "Sales", "Marketing", "Finance", "HR", "IT", "Operations")
    Locations = @("New York", "London", "Tokyo", "Sydney", "Toronto")
    JobTitles = @(
        "Software Engineer", "Senior Developer", "Product Manager", "Sales Representative",
        "Marketing Specialist", "Financial Analyst", "HR Manager", "IT Administrator"
    )
}

Write-Host "=========================================="
Write-Host "Entra ID Test Data Generator v4"
Write-Host "=========================================="
Write-Host ""
Write-Host "Target Tenant: $TenantDomain"
Write-Host "Mode: $(if ($SimulateChanges) { 'Simulate Changes' } else { 'Create New Data' })"
if ($SetupAutopilot) {
    Write-Host "Autopilot: Enabled (Tags: $($AutopilotGroupTags -join ', '))"
}
Write-Host ""

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..."
Write-Host "You'll be prompted to authenticate with Global Administrator credentials."
Write-Host ""

$requiredScopes = @(
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Directory.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All"
)

# Add Autopilot scopes if needed
if ($SetupAutopilot) {
    $requiredScopes += "DeviceManagementServiceConfig.ReadWrite.All"
}

try {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    $context = Get-MgContext

    if (-not $context) {
        Write-Error "Failed to connect to Microsoft Graph"
        exit 1
    }

    Write-Host "Connected successfully as: $($context.Account)"
    Write-Host ""
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

#region Helper Functions - Users, Groups, Roles

function New-TestUser {
    param(
        [int]$Index,
        [string]$Department,
        [string]$Location,
        [string]$JobTitle,
        [switch]$Disabled
    )

    $userPrincipalName = "$($script:Config.TestPrefix)User$Index@$TenantDomain"
    $displayName = "Test User $Index"
    $mailNickname = "$($script:Config.TestPrefix)User$Index"

    $userParams = @{
        AccountEnabled = -not $Disabled
        DisplayName = $displayName
        MailNickname = $mailNickname
        UserPrincipalName = $userPrincipalName
        PasswordProfile = $script:Config.PasswordProfile
        Department = $Department
        OfficeLocation = $Location
        JobTitle = $JobTitle
        UsageLocation = "US"
    }

    try {
        # Check if user exists first before creating
        $existingUser = Get-MgUser -Filter "userPrincipalName eq '$userPrincipalName'" -ErrorAction SilentlyContinue

        if ($existingUser) {
            Write-Host "  User already exists: $userPrincipalName" -ForegroundColor Yellow
            return $existingUser
        }

        $user = New-MgUser @userParams -ErrorAction Stop
        Write-Host "  Created user: $userPrincipalName" -ForegroundColor Green
        return $user
    }
    catch {
        Write-Warning "  Failed to create user $userPrincipalName : $_"
        return $null
    }
}

function New-TestGroup {
    param(
        [string]$Name,
        [string]$Description,
        [switch]$SecurityEnabled,
        [switch]$MailEnabled,
        [switch]$RoleAssignable,
        [string]$MembershipRule
    )

    $mailNickname = $Name -replace '[^a-zA-Z0-9]', ''

    # Check if group exists first
    try {
        $existingGroup = Get-MgGroup -Filter "displayName eq '$Name'" -ErrorAction SilentlyContinue
        if ($existingGroup) {
            Write-Host "  Group already exists: $Name" -ForegroundColor Yellow
            return $existingGroup
        }
    }
    catch {
        # Continue if check fails
    }

    $groupParams = @{
        DisplayName = $Name
        Description = $Description
        MailNickname = $mailNickname
        SecurityEnabled = $SecurityEnabled.IsPresent
    }

    # Only set MailEnabled for Unified groups, not standalone mail-enabled groups
    if ($MailEnabled -and -not $SecurityEnabled) {
        # Create as Microsoft 365 (Unified) group
        $groupParams['GroupTypes'] = @("Unified")
        $groupParams['MailEnabled'] = $true
    }
    else {
        $groupParams['MailEnabled'] = $false
    }

    # Role assignable groups must be security-enabled
    if ($RoleAssignable) {
        $groupParams['IsAssignableToRole'] = $true
        $groupParams['SecurityEnabled'] = $true
    }

    # Dynamic groups
    if ($MembershipRule) {
        $groupParams['GroupTypes'] = @("DynamicMembership")
        $groupParams['MembershipRule'] = $MembershipRule
        $groupParams['MembershipRuleProcessingState'] = "On"
    }

    try {
        $group = New-MgGroup @groupParams -ErrorAction Stop
        Write-Host "  Created group: $Name" -ForegroundColor Green
        return $group
    }
    catch {
        Write-Warning "  Failed to create group $Name : $_"
        return $null
    }
}

function Add-GroupMember {
    param(
        [string]$GroupId,
        [string]$MemberId,
        [switch]$IsGroup
    )

    try {
        # Check if already a member
        $existingMembers = Get-MgGroupMember -GroupId $GroupId -ErrorAction SilentlyContinue
        if ($existingMembers.Id -contains $MemberId) {
            Write-Verbose "    Member already in group"
            return
        }

        $body = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/$(if ($IsGroup) { 'groups' } else { 'directoryObjects' })/$MemberId"
        }

        New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $body -ErrorAction Stop
        Write-Host "    Added member to group"
    }
    catch {
        if ($_.Exception.Message -match "already exists|already a member") {
            Write-Verbose "    Member already in group"
        }
        else {
            Write-Warning "    Failed to add member: $_"
        }
    }
}

function Add-DirectoryRole {
    param(
        [string]$RoleDisplayName,
        [string]$PrincipalId,
        [switch]$MakePermanent
    )

    try {
        $roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$RoleDisplayName'" -ErrorAction SilentlyContinue

        if (-not $roleDefinition) {
            Write-Warning "    Role not found: $RoleDisplayName"
            return
        }

        if ($MakePermanent) {
            # Check if already assigned
            $existing = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$PrincipalId' and roleDefinitionId eq '$($roleDefinition.Id)'" -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host "    Role already assigned: $RoleDisplayName" -ForegroundColor Yellow
                return
            }

            $params = @{
                PrincipalId = $PrincipalId
                RoleDefinitionId = $roleDefinition.Id
                DirectoryScopeId = "/"
            }

            New-MgRoleManagementDirectoryRoleAssignment @params -ErrorAction Stop
            Write-Host "    Assigned permanent role: $RoleDisplayName" -ForegroundColor Green
        }
        else {
            $params = @{
                Action = "adminAssign"
                PrincipalId = $PrincipalId
                RoleDefinitionId = $roleDefinition.Id
                DirectoryScopeId = "/"
                Justification = "Test data generation"
                ScheduleInfo = @{
                    StartDateTime = (Get-Date).ToString("o")
                    Expiration = @{
                        Type = "noExpiration"
                    }
                }
            }

            New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params -ErrorAction Stop
            Write-Host "    Assigned PIM-eligible role: $RoleDisplayName" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "    Failed to assign role $RoleDisplayName : $_"
    }
}

function New-TestAppRegistration {
    param(
        [string]$DisplayName,
        [string[]]$RequiredResourceAccess
    )

    try {
        # Check if app already exists
        $existingApp = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue
        if ($existingApp) {
            Write-Host "  App already exists: $DisplayName" -ForegroundColor Yellow
            $existingSp = Get-MgServicePrincipal -Filter "appId eq '$($existingApp.AppId)'" -ErrorAction SilentlyContinue
            return @{
                Application = $existingApp
                ServicePrincipal = $existingSp
            }
        }

        $appParams = @{
            DisplayName = $DisplayName
            SignInAudience = "AzureADMyOrg"
        }

        $app = New-MgApplication @appParams -ErrorAction Stop

        $spParams = @{
            AppId = $app.AppId
        }

        $sp = New-MgServicePrincipal @spParams -ErrorAction Stop

        Write-Host "  Created app: $DisplayName (AppId: $($app.AppId))" -ForegroundColor Green

        return @{
            Application = $app
            ServicePrincipal = $sp
        }
    }
    catch {
        Write-Warning "  Failed to create app $DisplayName : $_"
        return $null
    }
}

function Invoke-SimulateUserLogin {
    <#
    .SYNOPSIS
        Simulates a user login to generate sign-in activity logs
    .DESCRIPTION
        Attempts to authenticate a user using the Resource Owner Password Credentials (ROPC) flow.
        This is useful for generating sign-in logs for testing purposes.

        IMPORTANT: This will likely FAIL if Security Defaults are enabled in your tenant (which is good!).
        Security Defaults block ROPC flow for security reasons. This failure is expected and safe.

        If you need successful logins for testing, you have two options:
        1. Disable Security Defaults (not recommended for production)
        2. Use browser-based authentication flows instead
    .NOTES
        - ROPC flow is not recommended for production applications
        - Requires the Microsoft Azure PowerShell client ID
        - Will fail with MFA-enabled accounts (by design)
    #>
    param(
        [string]$UserPrincipalName,
        [securestring]$Password
    )

    $clientId = "1950a258-227b-4e31-a9cf-717495945fc2"
    $tokenUri = "https://login.microsoftonline.com/$TenantDomain/oauth2/v2.0/token"

    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    )

    $body = @{
        client_id  = $clientId
        grant_type = "password"
        scope      = "openid profile User.Read"
        username   = $UserPrincipalName
        password   = $plainPassword
    }

    try {
        $null = Invoke-RestMethod -Uri $tokenUri -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body -ErrorAction Stop
        Write-Host "  [Login] Success: $UserPrincipalName" -ForegroundColor Green
    }
    catch {
        Write-Warning "  [Login] Blocked/Failed for $UserPrincipalName"
    }
}

#endregion

#region Helper Functions - Autopilot

function New-AutopilotDynamicGroup {
    <#
    .SYNOPSIS
        Creates a dynamic Azure AD group for Autopilot devices with a specific Group Tag.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$GroupTag,

        [Parameter(Mandatory)]
        [string]$GroupNamePrefix
    )

    $GroupName = "$GroupNamePrefix$GroupTag"
    $GroupDescription = "Dynamic group for Autopilot devices with Group Tag: $GroupTag"

    # Membership rule based on the OrderID (Group Tag) in devicePhysicalIds
    # See: https://learn.microsoft.com/en-us/mem/autopilot/enrollment-autopilot
    $MembershipRule = "(device.devicePhysicalIds -any (_ -eq `"[OrderID]:$GroupTag`"))"

    Write-Host "  Creating dynamic group: $GroupName" -ForegroundColor Yellow

    # Check if group already exists
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

    if ($ExistingGroup) {
        Write-Host "    Group '$GroupName' already exists (ID: $($ExistingGroup.Id))" -ForegroundColor Yellow
        return $ExistingGroup
    }

    $GroupParams = @{
        DisplayName                   = $GroupName
        Description                   = $GroupDescription
        MailEnabled                   = $false
        MailNickname                  = $GroupName.Replace(" ", "").Replace("-", "")
        SecurityEnabled               = $true
        GroupTypes                    = @("DynamicMembership")
        MembershipRule                = $MembershipRule
        MembershipRuleProcessingState = "On"
    }

    try {
        $NewGroup = New-MgGroup -BodyParameter $GroupParams
        Write-Host "    Created group: $GroupName (ID: $($NewGroup.Id))" -ForegroundColor Green
        return $NewGroup
    }
    catch {
        Write-Error "    Failed to create group '$GroupName': $_"
        return $null
    }
}

function New-AutopilotDeploymentProfile {
    <#
    .SYNOPSIS
        Creates a Windows Autopilot deployment profile.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$GroupTag
    )

    Write-Host "  Creating Autopilot deployment profile: $ProfileName" -ForegroundColor Yellow

    # Check if profile already exists
    $ExistingProfile = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" |
        Select-Object -ExpandProperty value |
        Where-Object { $_.displayName -eq $ProfileName }

    if ($ExistingProfile) {
        Write-Host "    Profile '$ProfileName' already exists (ID: $($ExistingProfile.id))" -ForegroundColor Yellow
        return $ExistingProfile
    }

    # Define the deployment profile settings
    # Using Azure AD Join with User-driven deployment
    $ProfileBody = @{
        "@odata.type"                            = "#microsoft.graph.azureADWindowsAutopilotDeploymentProfile"
        displayName                              = $ProfileName
        description                              = "Autopilot deployment profile for Group Tag: $GroupTag"
        language                                 = "os-default"
        extractHardwareHash                      = $true
        deviceNameTemplate                       = "AP-%SERIAL%"
        deviceType                               = "windowsPc"
        enableWhiteGlove                         = $true
        roleScopeTagIds                          = @()
        hybridAzureADJoinSkipConnectivityCheck   = $false
        outOfBoxExperienceSettings               = @{
            "@odata.type"             = "microsoft.graph.outOfBoxExperienceSettings"
            hidePrivacySettings       = $true
            hideEULA                  = $true
            userType                  = "standard"
            deviceUsageType           = "singleUser"
            skipKeyboardSelectionPage = $true
            hideEscapeLink            = $true
        }
        enrollmentStatusScreenSettings           = @{
            hideInstallationProgress                         = $false
            allowDeviceUseBeforeProfileAndAppInstallComplete = $false
            blockDeviceSetupRetryByUser                      = $false
            allowLogCollectionOnInstallFailure               = $true
            customErrorMessage                               = "An error occurred during setup. Please contact IT support."
            installProgressTimeoutInMinutes                  = 60
            allowDeviceUseOnInstallFailure                   = $false
        }
    }

    try {
        $NewProfile = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" `
            -Body ($ProfileBody | ConvertTo-Json -Depth 10) `
            -ContentType "application/json"

        Write-Host "    Created profile: $ProfileName (ID: $($NewProfile.id))" -ForegroundColor Green
        return $NewProfile
    }
    catch {
        Write-Error "    Failed to create profile '$ProfileName': $_"
        return $null
    }
}

function Set-AutopilotProfileAssignment {
    <#
    .SYNOPSIS
        Assigns an Autopilot deployment profile to an Azure AD group.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProfileId,

        [Parameter(Mandatory)]
        [string]$GroupId,

        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$GroupName
    )

    Write-Host "  Assigning profile '$ProfileName' to group '$GroupName'" -ForegroundColor Yellow

    # Check existing assignments
    $ExistingAssignments = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments"

    $AlreadyAssigned = $ExistingAssignments.value | Where-Object {
        $_.target.groupId -eq $GroupId
    }

    if ($AlreadyAssigned) {
        Write-Host "    Profile already assigned to group" -ForegroundColor Yellow
        return
    }

    $AssignmentBody = @{
        target = @{
            "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
            groupId       = $GroupId
        }
    }

    try {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments" `
            -Body ($AssignmentBody | ConvertTo-Json -Depth 5) `
            -ContentType "application/json" | Out-Null

        Write-Host "    Assignment created successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "    Failed to assign profile: $_"
    }
}

#endregion

# Main Execution
if ($SimulateChanges) {

    Write-Host "SIMULATING CHANGES & ACTIVITY"

    Write-Host ""

    $confirmation = Read-Host "Continue? (Y/N)"
    if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
        Write-Warning "Operation cancelled"
        exit 0
    }

    # Get existing test users
    $testUsers = Get-MgUser -Filter "startswith(userPrincipalName, '$($script:Config.TestPrefix)')" -All `
                            -Property "Id","UserPrincipalName","AccountEnabled","Department" -ErrorAction SilentlyContinue

    if ($testUsers.Count -eq 0) {
        Write-Warning "No existing test users found. Run without -SimulateChanges first."
        exit 1
    }

    Write-Host "Found $($testUsers.Count) existing test users"
    Write-Host ""

    # CHANGE 1: Toggle account status
    Write-Host "Step 1: Toggling account status..."
    $usersToToggle = $testUsers | Get-Random -Count ([Math]::Min(2, $testUsers.Count))
    foreach ($user in $usersToToggle) {
        $currentStatus = if ($null -eq $user.AccountEnabled) { $false } else { $user.AccountEnabled }
        $newStatus = -not $currentStatus

        Update-MgUser -UserId $user.Id -BodyParameter @{ AccountEnabled = $newStatus }
        Write-Host "  $($user.UserPrincipalName): AccountEnabled = $newStatus"
    }

    # CHANGE 2: Modify departments
    Write-Host "Step 2: Changing departments..."
    $usersToModify = $testUsers | Get-Random -Count ([Math]::Max(1, [Math]::Floor($testUsers.Count * 0.15)))
    foreach ($user in $usersToModify) {
        $newDept = $script:Config.Departments | Get-Random
        Update-MgUser -UserId $user.Id -BodyParameter @{ Department = $newDept }
        Write-Host "  $($user.UserPrincipalName): Department = $newDept"
    }

    # CHANGE 3: Group memberships
    Write-Host "Step 3: Modifying group memberships..."
    $testGroups = Get-MgGroup -Filter "startswith(displayName, '$($script:Config.TestPrefix)')" -All -ErrorAction SilentlyContinue

    if ($testGroups.Count -gt 0) {
        $randomGroup = $testGroups | Get-Random
        $randomUsers = $testUsers | Get-Random -Count ([Math]::Min(5, $testUsers.Count))

        foreach ($user in $randomUsers) {
            Add-GroupMember -GroupId $randomGroup.Id -MemberId $user.Id
        }
    }

    # CHANGE 4: Simulate logins
    Write-Host "Step 4: Simulating random user logins..."
    $enabledUsers = $testUsers | Where-Object { $_.AccountEnabled -eq $true }
    if ($enabledUsers.Count -gt 0) {
        $usersToLogin = $enabledUsers | Get-Random -Count ([Math]::Min(5, $enabledUsers.Count))

        # Create secure password once before the loop
        $securePass = ConvertTo-SecureString -String $script:Config.PasswordProfile.Password -AsPlainText -Force

        foreach ($u in $usersToLogin) {
            Invoke-SimulateUserLogin -UserPrincipalName $u.UserPrincipalName -Password $securePass
            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 3)
        }
    }

    # CHANGE 5: Legacy Per-User MFA (Deprecated but useful for testing)
    Write-Host "Step 5: Assigning Legacy Per-User MFA..."
    Write-Host "  Note: Microsoft is deprecating per-user MFA. This may fail in some tenants."

    $legacyMfaUsers = $testUsers | Get-Random -Count ([Math]::Min(3, $testUsers.Count))
    $legacyMfaSuccess = 0

    foreach ($u in $legacyMfaUsers) {
        try {
            # Attempt to set legacy per-user MFA
            # Note: This uses the older Azure AD PowerShell approach via Graph
            # State can be: Disabled, Enabled, Enforced
            $mfaRequirement = @{
                RelyingParty = "*"
                State = "Enforced"
                RememberDevicesNotIssuedBefore = (Get-Date).AddDays(-1).ToString("o")
            }

            Update-MgUser -UserId $u.Id -BodyParameter @{
                StrongAuthenticationRequirements = @($mfaRequirement)
            } -ErrorAction Stop

            Write-Host "  Legacy MFA 'Enforced' for: $($u.UserPrincipalName)" -ForegroundColor Green
            $legacyMfaSuccess++
        }
        catch {
            # Legacy MFA may not be supported in all tenants anymore
            if ($_.Exception.Message -match "does not support|not supported|invalid") {
                Write-Warning "  Legacy per-user MFA not supported in this tenant (deprecated by Microsoft)"
                break  # Don't try the rest
            }
            else {
                Write-Warning "  Failed to set legacy MFA for $($u.UserPrincipalName): $($_.Exception.Message)"
            }
        }
    }

    if ($legacyMfaSuccess -eq 0 -and $legacyMfaUsers.Count -gt 0) {
        Write-Host "  Legacy per-user MFA appears to be disabled/unsupported in this tenant." -ForegroundColor Yellow
        Write-Host "  This is expected as Microsoft is phasing out per-user MFA in favor of Conditional Access." -ForegroundColor Yellow
    }

    # CHANGE 6: Modern MFA (Authentication Methods)
    Write-Host "Step 6: Registering Modern Authentication Methods..."
    Write-Host "  Registering phone authentication methods for users..."

    # Select users who didn't get legacy MFA
    $modernMfaUsers = $testUsers | Where-Object { $_.Id -notin $legacyMfaUsers.Id } | Get-Random -Count ([Math]::Min(3, $testUsers.Count))
    $modernMfaSuccess = 0

    foreach ($u in $modernMfaUsers) {
        try {
            # Check if user already has phone methods registered
            $existingPhones = Get-MgUserAuthenticationPhoneMethod -UserId $u.Id -ErrorAction SilentlyContinue

            if ($existingPhones) {
                Write-Host "  User already has phone method: $($u.UserPrincipalName)" -ForegroundColor Yellow
                continue
            }

            # Generate random phone number
            $phoneNumber = "+1 555{0:D7}" -f (Get-Random -Minimum 1000000 -Maximum 9999999)

            $phoneParams = @{
                phoneNumber = $phoneNumber
                phoneType = "mobile"
            }

            New-MgUserAuthenticationPhoneMethod -UserId $u.Id -BodyParameter $phoneParams -ErrorAction Stop
            Write-Host "  Modern MFA (Phone) registered for: $($u.UserPrincipalName)" -ForegroundColor Green
            $modernMfaSuccess++
        }
        catch {
            if ($_.Exception.Message -match "already exists|AlreadyExists") {
                Write-Host "  Phone method already exists for: $($u.UserPrincipalName)" -ForegroundColor Yellow
            }
            else {
                Write-Warning "  Failed to register modern MFA for $($u.UserPrincipalName): $($_.Exception.Message)"
            }
        }
    }

    Write-Host "  Successfully registered modern MFA for $modernMfaSuccess users"

    Write-Host ""

    Write-Host "CHANGES SIMULATION COMPLETE"

    Write-Host ""
    Write-Host "Summary of changes:"
    Write-Host "  Account status toggled: $($usersToToggle.Count) users"
    Write-Host "  Departments changed: $($usersToModify.Count) users"
    Write-Host "  Group memberships modified: Yes"
    Write-Host "  User logins simulated: $($usersToLogin.Count) users"
    Write-Host "  Legacy MFA assigned: $legacyMfaSuccess users"
    Write-Host "  Modern MFA methods registered: $modernMfaSuccess users"
    Write-Host ""
    Write-Host "Next Steps:"
    Write-Host "1. Run your data collection scripts to detect these changes"
    Write-Host "2. Compare with previous day's data to verify delta detection"
    Write-Host ""
    if ($legacyMfaSuccess -eq 0 -and $legacyMfaUsers.Count -gt 0) {
        Write-Host "Note: Legacy per-user MFA failed. This is expected in modern tenants." -ForegroundColor Yellow
        Write-Host "      Consider testing MFA policies through Conditional Access instead." -ForegroundColor Yellow
        Write-Host ""
    }

} else {

    Write-Host "CREATING NEW TEST DATA"

    Write-Host ""

    # PHASE 1: Create Users
    Write-Host "Phase 1: Creating $UserCount test users..."
    $createdUsers = @()

    for ($i = 1; $i -le $UserCount; $i++) {
        $dept = $script:Config.Departments | Get-Random
        $location = $script:Config.Locations | Get-Random
        $jobTitle = $script:Config.JobTitles | Get-Random
        $disabled = ($i % 20 -eq 0)

        $user = New-TestUser -Index $i -Department $dept -Location $location -JobTitle $jobTitle -Disabled:$disabled

        if ($user) {
            $createdUsers += $user
        }

        if ($i % 10 -eq 0) {
            Write-Host "  Progress: $i / $UserCount users processed"
        }
    }

    Write-Host "Created $($createdUsers.Count) users"
    Write-Host ""

    # PHASE 2: Assign Licenses
    Write-Host "Phase 2: Assigning E5 licenses..."

    $e5License = Get-MgSubscribedSku -ErrorAction SilentlyContinue | Where-Object { $_.SkuPartNumber -like "*E5*" } | Select-Object -First 1

    if ($e5License) {
        Write-Host "Found license: $($e5License.SkuPartNumber)"

        $licensedCount = 0
        foreach ($user in $createdUsers) {
            if (-not $user.AccountEnabled) { continue }

            if ($e5License.ConsumedUnits -ge $e5License.PrepaidUnits.Enabled) {
                Write-Warning "  No more licenses available"
                break
            }

            try {
                $licenseParams = @{
                    AddLicenses = @(@{ SkuId = $e5License.SkuId })
                    RemoveLicenses = @()
                }

                Set-MgUserLicense -UserId $user.Id -BodyParameter $licenseParams -ErrorAction Stop
                $licensedCount++

                if ($licensedCount % 10 -eq 0) {
                    Write-Host "  Assigned $licensedCount licenses..."
                }
            }
            catch {
                Write-Warning "  Failed to assign license to $($user.UserPrincipalName)"
            }
        }

        Write-Host "Assigned $licensedCount E5 licenses"
    }
    else {
        Write-Warning "No E5 license found in tenant"
    }

    Write-Host ""

    # PHASE 3: Create Groups
    Write-Host "Phase 3: Creating groups..."

    $groups = @()

    # Department security groups
    foreach ($dept in $script:Config.Departments) {
        $groupName = "$($script:Config.TestPrefix)-$dept-Team"
        $group = New-TestGroup -Name $groupName `
                               -Description "All users in $dept department" `
                               -SecurityEnabled

        if ($group) {
            $groups += $group
            $deptUsers = $createdUsers | Where-Object { $_.Department -eq $dept }
            foreach ($user in $deptUsers) {
                Add-GroupMember -GroupId $group.Id -MemberId $user.Id
            }
        }
    }

    # Role-assignable security group with SecurityEnabled explicitly set
    $adminGroupName = "$($script:Config.TestPrefix)-IT-Admins"
    $adminGroup = New-TestGroup -Name $adminGroupName `
                                -Description "IT administrators with elevated privileges" `
                                -SecurityEnabled `
                                -RoleAssignable

    if ($adminGroup) {
        $groups += $adminGroup
        $itUsers = $createdUsers | Where-Object { $_.Department -eq "IT" } | Select-Object -First 5
        foreach ($user in $itUsers) {
            Add-GroupMember -GroupId $adminGroup.Id -MemberId $user.Id
        }
    }

    # Microsoft 365 group
    $m365GroupName = "$($script:Config.TestPrefix)-AllCompany"
    $m365Group = New-TestGroup -Name $m365GroupName `
                               -Description "Company-wide collaboration group" `
                               -MailEnabled

    if ($m365Group) {
        $groups += $m365Group
        $randomUsers = $createdUsers | Where-Object { $_.AccountEnabled } | Get-Random -Count ([Math]::Min(20, $createdUsers.Count))
        foreach ($user in $randomUsers) {
            Add-GroupMember -GroupId $m365Group.Id -MemberId $user.Id
        }
    }

    # Dynamic group
    $dynamicGroupName = "$($script:Config.TestPrefix)-Engineers-Dynamic"
    $dynamicGroup = New-TestGroup -Name $dynamicGroupName `
                                  -Description "All users with 'Engineer' in job title" `
                                  -SecurityEnabled `
                                  -MembershipRule "(user.jobTitle -contains ""Engineer"")"

    if ($dynamicGroup) {
        $groups += $dynamicGroup
    }

    Write-Host "Created $($groups.Count) groups"
    Write-Host ""

    # PHASE 4: Nested Groups
    if ($CreateNestedGroups) {
        Write-Host "Phase 4: Creating nested group hierarchy..."

        $parentGroupName = "$($script:Config.TestPrefix)-AllEmployees-Parent"
        $parentGroup = New-TestGroup -Name $parentGroupName `
                                     -Description "Parent group containing all department groups" `
                                     -SecurityEnabled

        if ($parentGroup) {
            foreach ($group in $groups) {
                if ($group.DisplayName -like "*-Team") {
                    Add-GroupMember -GroupId $parentGroup.Id -MemberId $group.Id -IsGroup
                }
            }
            Write-Host "Created nested group structure"
        }
        Write-Host ""
    }

    # PHASE 5: Directory Roles
    Write-Host "Phase 5: Assigning directory roles..."

    if ($createdUsers.Count -gt 0) {
        $itUsers = $createdUsers | Where-Object { $_.Department -eq "IT" }

        if ($itUsers.Count -ge 1) {
            $userAdmin = $itUsers | Get-Random
            Add-DirectoryRole -RoleDisplayName "User Administrator" -PrincipalId $userAdmin.Id -MakePermanent
        }

        if ($itUsers.Count -ge 2) {
            $helpdeskAdmin = $itUsers | Get-Random
            Add-DirectoryRole -RoleDisplayName "Helpdesk Administrator" -PrincipalId $helpdeskAdmin.Id
        }

        if ($itUsers.Count -ge 3) {
            $secReader = $itUsers | Get-Random
            Add-DirectoryRole -RoleDisplayName "Security Reader" -PrincipalId $secReader.Id -MakePermanent
        }
    }

    if ($adminGroup) {
        Add-DirectoryRole -RoleDisplayName "Groups Administrator" -PrincipalId $adminGroup.Id -MakePermanent
    }

    Write-Host ""

    # PHASE 6: App Registrations
    Write-Host "Phase 6: Creating app registrations..."

    $apps = @()

    $hrApp = New-TestAppRegistration -DisplayName "$($script:Config.TestPrefix)-HR-System"
    if ($hrApp) { $apps += $hrApp }

    $mobileApp = New-TestAppRegistration -DisplayName "$($script:Config.TestPrefix)-Mobile-App"
    if ($mobileApp) { $apps += $mobileApp }

    $dashboardApp = New-TestAppRegistration -DisplayName "$($script:Config.TestPrefix)-Dashboard"
    if ($dashboardApp) { $apps += $dashboardApp }

    Write-Host "Created $($apps.Count) app registrations"
    Write-Host ""

    # PHASE 7: Windows Autopilot Setup (NEW in V4)
    if ($SetupAutopilot) {
        Write-Host "Phase 7: Setting up Windows Autopilot with Group Tags..."
        Write-Host "  Group Tags: $($AutopilotGroupTags -join ', ')"
        Write-Host ""

        $autopilotResults = @()

        foreach ($Tag in $AutopilotGroupTags) {
            Write-Host "  Processing Group Tag: $Tag" -ForegroundColor Cyan

            # Create dynamic group for this tag
            $autopilotGroup = New-AutopilotDynamicGroup -GroupTag $Tag -GroupNamePrefix $AutopilotGroupNamePrefix

            # Create deployment profile for this tag
            $profileName = "$AutopilotGroupNamePrefix$Tag-Profile"
            $deploymentProfile = New-AutopilotDeploymentProfile -ProfileName $profileName -GroupTag $Tag

            # Assign profile to group
            if ($autopilotGroup -and $deploymentProfile) {
                Set-AutopilotProfileAssignment `
                    -ProfileId $deploymentProfile.id `
                    -GroupId $autopilotGroup.Id `
                    -ProfileName $profileName `
                    -GroupName $autopilotGroup.DisplayName
            }

            $autopilotResults += [PSCustomObject]@{
                GroupTag    = $Tag
                GroupName   = $autopilotGroup.DisplayName
                GroupId     = $autopilotGroup.Id
                ProfileName = $deploymentProfile.displayName
                ProfileId   = $deploymentProfile.id
            }

            Write-Host ""
        }

        Write-Host "Autopilot setup complete for $($AutopilotGroupTags.Count) group tag(s)"
        Write-Host ""
    }

    # Summary

    Write-Host "TEST DATA CREATION COMPLETE"
    Write-Host ""
    Write-Host "Summary:"
    Write-Host "  Users created: $($createdUsers.Count)"
    Write-Host "  Groups created: $($groups.Count)"
    Write-Host "  Apps created: $($apps.Count)"
    if ($SetupAutopilot) {
        Write-Host "  Autopilot Group Tags: $($AutopilotGroupTags.Count)"
        Write-Host ""
        Write-Host "Autopilot Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Register devices with Group Tag using:"
        Write-Host "     - OEM registration"
        Write-Host "     - Manual Intune upload"
        Write-Host "     - PowerShell: Get-WindowsAutopilotInfo.ps1 -Online -GroupTag '$($AutopilotGroupTags[0])'"
        Write-Host "  2. Devices will auto-join the dynamic group: $AutopilotGroupNamePrefix$($AutopilotGroupTags[0])"
        Write-Host "  3. Deployment profile applied during OOBE"
    }
    Write-Host ""
}

Disconnect-MgGraph
Write-Host ""
Write-Host "Script complete!"
