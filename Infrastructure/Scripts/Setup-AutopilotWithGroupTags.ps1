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

function Set-IntuneMdmMamScope {
    <#
    .SYNOPSIS
        Configures MDM and MAM User Scope for Windows Automatic Enrollment (required for Autopilot).
    .DESCRIPTION
        Sets the MDM User Scope and optionally adds specific groups when scope is "Some".
        This is a prerequisite for Windows Autopilot to function properly.
    #>
    param(
        [ValidateSet("All", "Some", "None")]
        [string]$MdmScope = "Some",

        [ValidateSet("All", "Some", "None")]
        [string]$MamScope = "None",

        [string[]]$IncludedGroupIds,

        [switch]$WhatIf
    )

    Write-Host "Configuring MDM/MAM User Scope..." -ForegroundColor Yellow

    # Microsoft Intune MDM application ID (well-known)
    $IntuneMdmAppId = "0000000a-0000-0000-c000-000000000000"

    try {
        # Get current MDM policy
        $mdmPolicy = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$IntuneMdmAppId" `
            -ErrorAction Stop

        Write-Host "  Current MDM scope: $($mdmPolicy.appliesTo)" -ForegroundColor Gray

        # Map scope string to API value
        $appliesToValue = switch ($MdmScope) {
            "All"  { "all" }
            "Some" { "selected" }
            "None" { "none" }
        }

        # Update scope if needed
        if ($mdmPolicy.appliesTo -ne $appliesToValue) {
            if ($WhatIf) {
                Write-Host "  [WhatIf] Would set MDM scope to '$MdmScope'" -ForegroundColor Magenta
            }
            else {
                $updateBody = @{ appliesTo = $appliesToValue }

                Invoke-MgGraphRequest -Method PATCH `
                    -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$IntuneMdmAppId" `
                    -Body ($updateBody | ConvertTo-Json) `
                    -ContentType "application/json" | Out-Null

                Write-Host "  MDM User Scope set to '$MdmScope'" -ForegroundColor Green
            }
        }
        else {
            Write-Host "  MDM scope already set to '$MdmScope'" -ForegroundColor Cyan
        }

        # Add groups to MDM scope if "Some" is selected and groups are provided
        if ($MdmScope -eq "Some" -and $IncludedGroupIds -and $IncludedGroupIds.Count -gt 0) {
            Write-Host "  Adding groups to MDM scope..." -ForegroundColor Yellow

            foreach ($GroupId in $IncludedGroupIds) {
                if ($WhatIf) {
                    Write-Host "    [WhatIf] Would add group $GroupId to MDM scope" -ForegroundColor Magenta
                    continue
                }

                try {
                    # Check if group is already included
                    $existingGroups = Invoke-MgGraphRequest -Method GET `
                        -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$IntuneMdmAppId/includedGroups" `
                        -ErrorAction SilentlyContinue

                    $alreadyIncluded = $existingGroups.value | Where-Object { $_.id -eq $GroupId }

                    if ($alreadyIncluded) {
                        Write-Host "    Group $GroupId already in MDM scope" -ForegroundColor Cyan
                    }
                    else {
                        # Add group to MDM policy
                        $addGroupBody = @{
                            "@odata.id" = "https://graph.microsoft.com/beta/groups/$GroupId"
                        }

                        Invoke-MgGraphRequest -Method POST `
                            -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$IntuneMdmAppId/includedGroups/`$ref" `
                            -Body ($addGroupBody | ConvertTo-Json) `
                            -ContentType "application/json" | Out-Null

                        Write-Host "    Added group $GroupId to MDM scope" -ForegroundColor Green
                    }
                }
                catch {
                    Write-Warning "    Failed to add group $GroupId to MDM scope: $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        if ($_.Exception.Message -match "not found|404") {
            Write-Warning "  MDM policy not found. Intune may not be configured in this tenant."
            Write-Host "  Please configure MDM manually:" -ForegroundColor Yellow
            Write-Host "    1. Go to Entra Admin Center > Mobility (MDM and MAM)" -ForegroundColor Gray
            Write-Host "    2. Click 'Microsoft Intune'" -ForegroundColor Gray
            Write-Host "    3. Set MDM User Scope to 'Some' and add your groups" -ForegroundColor Gray
            return $false
        }
        else {
            Write-Warning "  Failed to configure MDM scope: $($_.Exception.Message)"
            return $false
        }
    }

    # Configure MAM if needed (similar logic)
    if ($MamScope -ne "None") {
        try {
            $mamPolicy = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/policies/mobileAppManagementPolicies/$IntuneMdmAppId" `
                -ErrorAction SilentlyContinue

            if ($mamPolicy) {
                $mamAppliesToValue = switch ($MamScope) {
                    "All"  { "all" }
                    "Some" { "selected" }
                    "None" { "none" }
                }

                if (-not $WhatIf -and $mamPolicy.appliesTo -ne $mamAppliesToValue) {
                    $updateBody = @{ appliesTo = $mamAppliesToValue }

                    Invoke-MgGraphRequest -Method PATCH `
                        -Uri "https://graph.microsoft.com/beta/policies/mobileAppManagementPolicies/$IntuneMdmAppId" `
                        -Body ($updateBody | ConvertTo-Json) `
                        -ContentType "application/json" | Out-Null

                    Write-Host "  MAM User Scope set to '$MamScope'" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Verbose "  MAM policy configuration skipped: $($_.Exception.Message)"
        }
    }

    return $true
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
    .DESCRIPTION
        Creates an Autopilot deployment profile via the Graph API using the format
        from the WindowsAutoPilotIntune PowerShell module.
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
    try {
        $ExistingProfiles = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" -ErrorAction Stop
        $ExistingProfile = $ExistingProfiles.value | Where-Object { $_.displayName -eq $ProfileName }

        if ($ExistingProfile) {
            Write-Host "  Profile '$ProfileName' already exists (ID: $($ExistingProfile.id))" -ForegroundColor Cyan
            return $ExistingProfile
        }
    }
    catch {
        Write-Warning "  Could not query existing profiles. Intune may not be configured in this tenant."
        Write-Warning "  Error: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "  To use Autopilot, ensure:" -ForegroundColor Yellow
        Write-Host "    1. Intune is licensed and configured in your tenant" -ForegroundColor Gray
        Write-Host "    2. You have the Intune Administrator or Global Administrator role" -ForegroundColor Gray
        Write-Host "    3. Windows Autopilot is enabled in Intune" -ForegroundColor Gray
        Write-Host ""
        return $null
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would create Autopilot deployment profile" -ForegroundColor Magenta
        return @{ id = "whatif-profile-id"; displayName = $ProfileName }
    }

    # Define the deployment profile as JSON using the exact format from WindowsAutoPilotIntune module
    # This format is proven to work with the Graph API
    $jsonBody = @"
{
    "@odata.type": "#microsoft.graph.azureADWindowsAutopilotDeploymentProfile",
    "displayName": "$ProfileName",
    "description": "Autopilot deployment profile for Group Tag: $GroupTag",
    "locale": "",
    "hardwareHashExtractionEnabled": true,
    "deviceNameTemplate": "AP-%SERIAL%",
    "deviceType": "windowsPc",
    "preprovisioningAllowed": false,
    "outOfBoxExperienceSetting": {
        "privacySettingsHidden": true,
        "eulaHidden": true,
        "userType": "standard",
        "deviceUsageType": "singleUser",
        "keyboardSelectionPageSkipped": true,
        "escapeLinkHidden": true
    }
}
"@

    try {
        $NewProfile = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" `
            -Body $jsonBody `
            -ContentType "application/json"

        Write-Host "  Created profile: $ProfileName (ID: $($NewProfile.id))" -ForegroundColor Green
        return $NewProfile
    }
    catch {
        Write-Warning "  Failed to create profile '$ProfileName': $($_.Exception.Message)"
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

# STEP 1: Create all dynamic groups first
Write-Host "Step 1: Creating Autopilot dynamic groups..." -ForegroundColor Cyan
$CreatedGroups = @{}

foreach ($Tag in $GroupTags) {
    $Group = New-AutopilotDynamicGroup -GroupTag $Tag -GroupNamePrefix $GroupNamePrefix -WhatIf:$WhatIf
    if ($Group) {
        $CreatedGroups[$Tag] = $Group
    }
}

Write-Host ""

# STEP 2: Configure MDM/MAM User Scope with the created groups
Write-Host "Step 2: Configuring MDM User Scope..." -ForegroundColor Cyan
$GroupIds = $CreatedGroups.Values | ForEach-Object { $_.Id } | Where-Object { $_ -and $_ -ne "whatif-group-id" }

$mdmConfigured = Set-IntuneMdmMamScope -MdmScope "Some" -IncludedGroupIds $GroupIds -WhatIf:$WhatIf

if (-not $mdmConfigured -and -not $WhatIf) {
    Write-Warning "MDM User Scope could not be configured automatically."
    Write-Host "Please configure it manually in Entra > Mobility (MDM and MAM)." -ForegroundColor Yellow
}

Write-Host ""

# STEP 3: Create deployment profiles and assign to groups
Write-Host "Step 3: Creating deployment profiles and assignments..." -ForegroundColor Cyan
$Results = @()

foreach ($Tag in $GroupTags) {
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "Processing Group Tag: $Tag" -ForegroundColor White
    Write-Host "----------------------------------------" -ForegroundColor Gray

    $Group = $CreatedGroups[$Tag]

    # Create deployment profile
    $ProfileName = "$GroupNamePrefix$Tag-Profile"
    $DeploymentProfile = New-AutopilotDeploymentProfile -ProfileName $ProfileName -GroupTag $Tag -WhatIf:$WhatIf

    # Assign profile to group if both exist
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
        GroupName   = if ($Group) { $Group.DisplayName } else { "N/A" }
        GroupId     = if ($Group) { $Group.Id } else { "N/A" }
        ProfileName = if ($DeploymentProfile) { $DeploymentProfile.displayName } else { "FAILED" }
        ProfileId   = if ($DeploymentProfile) { $DeploymentProfile.id } else { "N/A" }
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
