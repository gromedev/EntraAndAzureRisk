<#
.SYNOPSIS
    Automates Windows Autopilot setup using Group Tags with dynamic Azure AD groups.

.DESCRIPTION
    This script creates:
    1. Dynamic Azure AD groups based on Autopilot Group Tags
    2. Windows Autopilot deployment profiles
    3. Assigns profiles to the corresponding dynamic groups

.PARAMETER GroupTags
    Array of group tags to create. Each tag will get a dynamic group and deployment profile.
    Default: @("Standard")

.PARAMETER GroupNamePrefix
    Prefix for the dynamic group names. Default: "Autopilot-"

.PARAMETER AuthMethod
    Authentication method: "Interactive", "ServicePrincipal", or "ManagedIdentity"
    Default: "Interactive"

.PARAMETER TenantId
    Required for ServicePrincipal and ManagedIdentity auth methods.

.PARAMETER ClientId
    Required for ServicePrincipal auth. The App Registration client ID.

.PARAMETER ClientSecret
    Required for ServicePrincipal auth (if not using certificate).

.PARAMETER CertificateThumbprint
    Optional for ServicePrincipal auth. Use certificate instead of client secret.

.EXAMPLE
    # Interactive authentication with default "Standard" tag
    .\Setup-AutopilotWithGroupTags.ps1

.EXAMPLE
    # Multiple group tags
    .\Setup-AutopilotWithGroupTags.ps1 -GroupTags @("Standard", "Kiosk", "Developer")

.EXAMPLE
    # Using Service Principal
    .\Setup-AutopilotWithGroupTags.ps1 -AuthMethod ServicePrincipal -TenantId "your-tenant-id" -ClientId "app-id" -ClientSecret "secret"

.EXAMPLE
    # Using Managed Identity (from Azure Automation or Azure VM)
    .\Setup-AutopilotWithGroupTags.ps1 -AuthMethod ManagedIdentity -TenantId "your-tenant-id"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$GroupTags = @("Standard"),

    [Parameter()]
    [string]$GroupNamePrefix = "Autopilot-",

    [Parameter()]
    [ValidateSet("Interactive", "ServicePrincipal", "ManagedIdentity")]
    [string]$AuthMethod = "Interactive",

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$ClientSecret,

    [Parameter()]
    [string]$CertificateThumbprint,

    [Parameter()]
    [switch]$WhatIf
)

#region Functions

function Connect-ToGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using the specified authentication method.
    #>
    param(
        [string]$AuthMethod,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$CertificateThumbprint
    )

    # Required Graph scopes
    $Scopes = @(
        "DeviceManagementServiceConfig.ReadWrite.All",
        "Group.ReadWrite.All",
        "Directory.ReadWrite.All"
    )

    Write-Host "Connecting to Microsoft Graph using $AuthMethod authentication..." -ForegroundColor Cyan

    switch ($AuthMethod) {
        "Interactive" {
            Connect-MgGraph -Scopes $Scopes -NoWelcome
        }
        "ServicePrincipal" {
            if (-not $TenantId -or -not $ClientId) {
                throw "TenantId and ClientId are required for ServicePrincipal authentication."
            }

            if ($CertificateThumbprint) {
                Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
            }
            elseif ($ClientSecret) {
                $SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
                $Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)
                Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential -NoWelcome
            }
            else {
                throw "Either ClientSecret or CertificateThumbprint is required for ServicePrincipal authentication."
            }
        }
        "ManagedIdentity" {
            if (-not $TenantId) {
                throw "TenantId is required for ManagedIdentity authentication."
            }
            Connect-MgGraph -Identity -TenantId $TenantId -NoWelcome
        }
    }

    $Context = Get-MgContext
    if ($Context) {
        Write-Host "Connected to tenant: $($Context.TenantId)" -ForegroundColor Green
    }
    else {
        throw "Failed to connect to Microsoft Graph."
    }
}

function New-AutopilotDynamicGroup {
    <#
    .SYNOPSIS
        Creates a dynamic Azure AD group for Autopilot devices with a specific Group Tag.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$GroupTag,

        [Parameter(Mandatory)]
        [string]$GroupNamePrefix,

        [switch]$WhatIf
    )

    $GroupName = "$GroupNamePrefix$GroupTag"
    $GroupDescription = "Dynamic group for Autopilot devices with Group Tag: $GroupTag"

    # Membership rule based on the OrderID (Group Tag) in devicePhysicalIds
    # See: https://learn.microsoft.com/en-us/mem/autopilot/enrollment-autopilot
    $MembershipRule = "(device.devicePhysicalIds -any (_ -eq `"[OrderID]:$GroupTag`"))"

    Write-Host "Creating dynamic group: $GroupName" -ForegroundColor Yellow

    # Check if group already exists
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

    if ($ExistingGroup) {
        Write-Host "  Group '$GroupName' already exists (ID: $($ExistingGroup.Id))" -ForegroundColor Cyan
        return $ExistingGroup
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would create group with rule: $MembershipRule" -ForegroundColor Magenta
        return @{ Id = "whatif-group-id"; DisplayName = $GroupName }
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
        Write-Host "  Created group: $GroupName (ID: $($NewGroup.Id))" -ForegroundColor Green
        return $NewGroup
    }
    catch {
        Write-Error "  Failed to create group '$GroupName': $_"
        throw
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
        [string]$GroupTag,

        [switch]$WhatIf
    )

    Write-Host "Creating Autopilot deployment profile: $ProfileName" -ForegroundColor Yellow

    # Check if profile already exists
    $ExistingProfile = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" |
        Select-Object -ExpandProperty value |
        Where-Object { $_.displayName -eq $ProfileName }

    if ($ExistingProfile) {
        Write-Host "  Profile '$ProfileName' already exists (ID: $($ExistingProfile.id))" -ForegroundColor Cyan
        return $ExistingProfile
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would create Autopilot deployment profile" -ForegroundColor Magenta
        return @{ id = "whatif-profile-id"; displayName = $ProfileName }
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

        Write-Host "  Created profile: $ProfileName (ID: $($NewProfile.id))" -ForegroundColor Green
        return $NewProfile
    }
    catch {
        Write-Error "  Failed to create profile '$ProfileName': $_"
        throw
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
        [string]$GroupName,

        [switch]$WhatIf
    )

    Write-Host "Assigning profile '$ProfileName' to group '$GroupName'" -ForegroundColor Yellow

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would assign profile to group" -ForegroundColor Magenta
        return
    }

    # Check existing assignments
    $ExistingAssignments = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments"

    $AlreadyAssigned = $ExistingAssignments.value | Where-Object {
        $_.target.groupId -eq $GroupId
    }

    if ($AlreadyAssigned) {
        Write-Host "  Profile already assigned to group" -ForegroundColor Cyan
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

        Write-Host "  Assignment created successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "  Failed to assign profile: $_"
        throw
    }
}

#endregion Functions

#region Main Script

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Windows Autopilot Setup with Group Tags" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check for Microsoft.Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "Installing Microsoft.Graph.Authentication module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
    Write-Host "Installing Microsoft.Graph.Groups module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Groups -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

# Connect to Graph
Connect-ToGraph -AuthMethod $AuthMethod -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -CertificateThumbprint $CertificateThumbprint

Write-Host ""
Write-Host "Processing Group Tags: $($GroupTags -join ', ')" -ForegroundColor Cyan
Write-Host ""

$Results = @()

foreach ($Tag in $GroupTags) {
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "Processing Group Tag: $Tag" -ForegroundColor White
    Write-Host "----------------------------------------" -ForegroundColor Gray

    # Create dynamic group
    $Group = New-AutopilotDynamicGroup -GroupTag $Tag -GroupNamePrefix $GroupNamePrefix -WhatIf:$WhatIf

    # Create deployment profile
    $ProfileName = "$GroupNamePrefix$Tag-Profile"
    $DeploymentProfile = New-AutopilotDeploymentProfile -ProfileName $ProfileName -GroupTag $Tag -WhatIf:$WhatIf

    # Assign profile to group
    if ($Group -and $DeploymentProfile) {
        Set-AutopilotProfileAssignment `
            -ProfileId $DeploymentProfile.id `
            -GroupId $Group.Id `
            -ProfileName $ProfileName `
            -GroupName $Group.DisplayName `
            -WhatIf:$WhatIf
    }

    $Results += [PSCustomObject]@{
        GroupTag    = $Tag
        GroupName   = $Group.DisplayName
        GroupId     = $Group.Id
        ProfileName = $DeploymentProfile.displayName
        ProfileId   = $DeploymentProfile.id
    }

    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Green
Write-Host " Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Display summary
Write-Host "Summary:" -ForegroundColor Cyan
$Results | Format-Table -AutoSize

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Register devices with the Group Tag using one of these methods:" -ForegroundColor White
Write-Host "   - OEM registration with Group Tag" -ForegroundColor Gray
Write-Host "   - Manual upload to Intune with Group Tag" -ForegroundColor Gray
Write-Host "   - PowerShell: Get-WindowsAutopilotInfo.ps1 -Online -GroupTag '$($GroupTags[0])'" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Devices will automatically join the dynamic group: $GroupNamePrefix$($GroupTags[0])" -ForegroundColor White
Write-Host ""
Write-Host "3. The Autopilot deployment profile will be applied during OOBE" -ForegroundColor White
Write-Host ""

# Disconnect from Graph
Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph" -ForegroundColor Gray

#endregion Main Script
