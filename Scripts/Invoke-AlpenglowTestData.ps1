#Requires -Version 7.0
<#
.SYNOPSIS
    Generates comprehensive test data for the Alpenglow/EntraRisk solution.

.DESCRIPTION
    Creates test users, groups, applications, Azure resources, policies, and relationships
    to exercise the historical tracking capabilities of the EntraRisk solution.

    Supports:
    - Entra ID: Users, Groups, Applications, Nested Groups
    - Ownership: Group owners, Application owners, Service Principal owners
    - Role Assignments: Direct (non-PIM) directory role assignments
    - PIM: Role Eligibility Assignments
    - Conditional Access: Policies, Named Locations
    - Intune: Compliance Policies, App Protection Policies
    - Azure Resources: VM, AKS, Key Vault, ACR, Storage, Automation, Function App, Logic App, Web App

    Edge types exercised:
    - groupMember, groupMemberTransitive (nested groups)
    - groupOwner, appOwner, spOwner (ownership edges)
    - directoryRole (direct role assignments)
    - pimEligible (PIM eligibility)
    - caPolicyExcludesPrincipal (CA policy exclusions)

    Just run it - no parameters needed!

.EXAMPLE
    ./Invoke-AlpenglowTestData.ps1
#>

# Suppress PSScriptAnalyzer warnings that are intentional for this interactive test data script
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI script requires colored console output')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test data secrets are not sensitive')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Feature detection intentionally ignores errors')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test data script - confirmation handled at menu level')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Functions operate on multiple resources')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Get-State is clearer than Get-State for this context')]
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [ValidateSet('Create', 'Changes', 'Cleanup')]
    [string]$Action,
    [string]$TestPrefix = 'Alpenglow-Test'
)

#region Configuration
$Config = @{
    UserCount       = 10
    GroupCount      = 5
    AppCount        = 3
    NestingDepth    = 4
    AzureLocation   = 'westeurope'
    AzureRgName     = 'rg-alpenglow-test'
}

$RoleDefinitions = @{
    HelpDeskAdmin   = '729827e3-9c14-49f7-bb1b-9608f156bbb8'
    SecurityReader  = '5d6b6bb7-de71-4623-b4af-96380a352509'
    GroupsAdmin     = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
}

$StateFile = Join-Path $PSScriptRoot 'AlpenglowTestData-State.json'

# HARD EXCLUSION - Members of this group are NEVER touched
$ExclusionGroupName = 'Admin-Exclude-From-Test'
$script:ExcludedUserIds = @()
$script:ExclusionGroupId = $null
#endregion

#region Helper Functions

function Connect-ToGraph {
    $context = Get-MgContext
    if (-not $context) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes @(
            'User.ReadWrite.All',
            'Group.ReadWrite.All',
            'Application.ReadWrite.All',
            'RoleManagement.ReadWrite.Directory',
            'Policy.ReadWrite.ConditionalAccess',
            'Policy.Read.All',
            'DeviceManagementConfiguration.ReadWrite.All',
            'DeviceManagementApps.ReadWrite.All'
        ) -NoWelcome
    }
}

function Connect-ToAzure {
    param([hashtable]$Caps)

    if (-not $Caps.HasAzModule) { return $false }

    try {
        $azContext = Get-AzContext -ErrorAction Stop
        if (-not $azContext) {
            Write-Host "Connecting to Azure..." -ForegroundColor Cyan
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        Write-Warning "Azure connection failed: $_"
        return $false
    }
}

function Get-TenantCapabilities {
    $caps = @{
        HasPIM      = $false
        HasCA       = $false
        HasIntune   = $false
        HasAzModule = $false
        HasAzAccess = $false
        TenantDomain = $null
        TenantId    = $null
    }

    # Get tenant info
    $org = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization'
    $caps.TenantDomain = ($org.value[0].verifiedDomains | Where-Object { $_.isDefault }).name
    $caps.TenantId = $org.value[0].id

    # Check PIM - silently fail if not available
    try {
        $null = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?$top=1' -ErrorAction Stop
        $caps.HasPIM = $true
    } catch { <# Feature not available #> }

    # Check Conditional Access - silently fail if not available
    try {
        $null = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$top=1' -ErrorAction Stop
        $caps.HasCA = $true
    } catch { <# Feature not available #> }

    # Check Intune - silently fail if not available
    try {
        $null = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies?$top=1' -ErrorAction Stop
        $caps.HasIntune = $true
    } catch { <# Feature not available #> }

    # Check Az module
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        $caps.HasAzModule = $true
        try {
            $azContext = Get-AzContext -ErrorAction SilentlyContinue
            if ($azContext) { $caps.HasAzAccess = $true }
        } catch { <# Not connected #> }
    }

    return $caps
}

function Initialize-ExclusionList {
    Write-Host "Loading exclusion list..." -ForegroundColor Gray

    try {
        $filter = [System.Web.HttpUtility]::UrlEncode("displayName eq '$ExclusionGroupName'")
        $groupResult = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter"

        if ($groupResult.value.Count -eq 0) {
            Write-Warning "Exclusion group '$ExclusionGroupName' not found - proceeding without exclusions"
            return
        }

        $script:ExclusionGroupId = $groupResult.value[0].id
        Write-Host "  Found exclusion group: $ExclusionGroupName" -ForegroundColor Gray

        $members = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($script:ExclusionGroupId)/transitiveMembers?`$select=id,displayName"
        $script:ExcludedUserIds = @($members.value | ForEach-Object { $_.id })

        if ($script:ExcludedUserIds.Count -gt 0) {
            Write-Host "  Protected users: $($script:ExcludedUserIds.Count) (members of $ExclusionGroupName)" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed to load exclusion list: $_ - proceeding without exclusions"
    }
}

function Test-IsExcluded($UserId) {
    return $script:ExcludedUserIds -contains $UserId
}

function Test-IsExcludedGroup($GroupId) {
    return $GroupId -eq $script:ExclusionGroupId
}

function Get-State {
    if (Test-Path $StateFile) {
        $loaded = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
        return @{
            users             = [System.Collections.ArrayList]@($loaded.users ?? @())
            groups            = [System.Collections.ArrayList]@($loaded.groups ?? @())
            apps              = [System.Collections.ArrayList]@($loaded.apps ?? @())
            memberships       = [System.Collections.ArrayList]@($loaded.memberships ?? @())
            credentials       = [System.Collections.ArrayList]@($loaded.credentials ?? @())
            groupOwnerships   = [System.Collections.ArrayList]@($loaded.groupOwnerships ?? @())
            appOwnerships     = [System.Collections.ArrayList]@($loaded.appOwnerships ?? @())
            spOwnerships      = [System.Collections.ArrayList]@($loaded.spOwnerships ?? @())
            directRoleAssignments = [System.Collections.ArrayList]@($loaded.directRoleAssignments ?? @())
            caPolicies        = [System.Collections.ArrayList]@($loaded.caPolicies ?? @())
            namedLocations    = [System.Collections.ArrayList]@($loaded.namedLocations ?? @())
            compliancePolicies = [System.Collections.ArrayList]@($loaded.compliancePolicies ?? @())
            appProtectionPolicies = [System.Collections.ArrayList]@($loaded.appProtectionPolicies ?? @())
            azureResources    = [System.Collections.ArrayList]@($loaded.azureResources ?? @())
        }
    }
    return @{
        users             = [System.Collections.ArrayList]@()
        groups            = [System.Collections.ArrayList]@()
        apps              = [System.Collections.ArrayList]@()
        memberships       = [System.Collections.ArrayList]@()
        credentials       = [System.Collections.ArrayList]@()
        groupOwnerships   = [System.Collections.ArrayList]@()
        appOwnerships     = [System.Collections.ArrayList]@()
        spOwnerships      = [System.Collections.ArrayList]@()
        directRoleAssignments = [System.Collections.ArrayList]@()
        caPolicies        = [System.Collections.ArrayList]@()
        namedLocations    = [System.Collections.ArrayList]@()
        compliancePolicies = [System.Collections.ArrayList]@()
        appProtectionPolicies = [System.Collections.ArrayList]@()
        azureResources    = [System.Collections.ArrayList]@()
    }
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Force
}

#endregion

#region Entra ID Create Functions

function New-TestUser($Prefix, $Suffix, $Domain) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-User-$Suffix-$id"
    $upn = "$Prefix-user-$Suffix-$id@$Domain".ToLower()

    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%'
    $password = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

    try {
        $user = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' -Body @{
            displayName       = $name
            userPrincipalName = $upn
            mailNickname      = "$Prefix-user-$Suffix-$id".ToLower()
            accountEnabled    = $true
            passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $true }
        }
        Write-Host "  + User: $name" -ForegroundColor Green
        return @{ id = $user.id; displayName = $name; upn = $upn }
    } catch {
        Write-Warning "  ! Failed: $name - $_"
        return $null
    }
}

function New-TestGroup($Prefix, $Suffix, [switch]$RoleAssignable) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-Group-$Suffix-$id"

    try {
        $body = @{
            displayName     = $name
            mailNickname    = "$Prefix-group-$Suffix-$id".ToLower()
            securityEnabled = $true
            mailEnabled     = $false
        }

        if ($RoleAssignable) {
            $body.isAssignableToRole = $true
            $body.groupTypes = @('Unified')
            $body.mailEnabled = $true
        }

        $group = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body $body
        $label = if ($RoleAssignable) { " [Role-Assignable]" } else { "" }
        Write-Host "  + Group: $name$label" -ForegroundColor Green
        return @{ id = $group.id; displayName = $name; roleAssignable = $RoleAssignable.IsPresent }
    } catch {
        Write-Warning "  ! Failed: $name - $_"
        return $null
    }
}

function New-TestApp($Prefix, $Suffix) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-App-$Suffix-$id"

    try {
        $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName    = $name
            signInAudience = 'AzureADMyOrg'
        }
        $sp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{
            appId = $app.appId
        }
        Write-Host "  + App: $name" -ForegroundColor Green
        return @{ appId = $app.id; spId = $sp.id; displayName = $name; credentials = @() }
    } catch {
        Write-Warning "  ! Failed: $name - $_"
        return $null
    }
}

function Add-GroupMember($GroupId, $MemberId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId"
        }
        return $true
    } catch {
        if ($_.Exception.Message -notmatch 'already exist') { Write-Warning "  ! Add member failed: $_" }
        return $false
    }
}

function Remove-GroupMember($GroupId, $MemberId) {
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/$MemberId/`$ref"
        return $true
    } catch { return $false }
}

function Add-Credential($SpId) {
    try {
        $result = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpId/addPassword" -Body @{
            passwordCredential = @{
                displayName = "Test-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                endDateTime = (Get-Date).AddDays(30).ToUniversalTime().ToString('o')
            }
        }
        return $result.keyId
    } catch { return $null }
}

function Remove-Credential($SpId, $KeyId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpId/removePassword" -Body @{ keyId = $KeyId }
        return $true
    } catch { return $false }
}

function Add-PimEligibility($PrincipalId, $RoleId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -Body @{
            action           = 'AdminAssign'
            principalId      = $PrincipalId
            roleDefinitionId = $RoleId
            directoryScopeId = '/'
            justification    = 'Alpenglow test'
            scheduleInfo     = @{
                startDateTime = (Get-Date).ToUniversalTime().ToString('o')
                expiration    = @{ type = 'AfterDuration'; duration = 'P7D' }
            }
        }
        return $true
    } catch {
        Write-Warning "  ! PIM eligibility failed: $_"
        return $false
    }
}

#region Ownership Functions

function Add-GroupOwner($GroupId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/owners/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerId"
        }
        return $true
    } catch {
        if ($_.Exception.Message -notmatch 'already exist') { Write-Warning "  ! Add group owner failed: $_" }
        return $false
    }
}

function Remove-GroupOwner($GroupId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/owners/$OwnerId/`$ref"
        return $true
    } catch { return $false }
}

function Add-AppOwner($AppId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/applications/$AppId/owners/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerId"
        }
        return $true
    } catch {
        if ($_.Exception.Message -notmatch 'already exist') { Write-Warning "  ! Add app owner failed: $_" }
        return $false
    }
}

function Remove-AppOwner($AppId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/applications/$AppId/owners/$OwnerId/`$ref"
        return $true
    } catch { return $false }
}

function Add-SpOwner($SpId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpId/owners/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerId"
        }
        return $true
    } catch {
        if ($_.Exception.Message -notmatch 'already exist') { Write-Warning "  ! Add SP owner failed: $_" }
        return $false
    }
}

function Remove-SpOwner($SpId, $OwnerId) {
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpId/owners/$OwnerId/`$ref"
        return $true
    } catch { return $false }
}

#endregion

#region Direct Role Assignment Functions

function Add-DirectRoleAssignment($PrincipalId, $RoleId) {
    try {
        $result = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' -Body @{
            principalId      = $PrincipalId
            roleDefinitionId = $RoleId
            directoryScopeId = '/'
        }
        return $result.id
    } catch {
        Write-Warning "  ! Direct role assignment failed: $_"
        return $null
    }
}

function Remove-DirectRoleAssignment($AssignmentId) {
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments/$AssignmentId"
        return $true
    } catch { return $false }
}

#endregion

#region Policy Create Functions

function New-TestNamedLocation($Prefix) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-Location-$id"

    try {
        $location = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations' -Body @{
            '@odata.type'    = '#microsoft.graph.ipNamedLocation'
            displayName      = $name
            isTrusted        = $false
            ipRanges         = @(
                @{ '@odata.type' = '#microsoft.graph.iPv4CidrRange'; cidrAddress = "10.$(Get-Random -Max 255).$(Get-Random -Max 255).0/24" }
            )
        }
        Write-Host "  + Named Location: $name" -ForegroundColor Green
        return @{ id = $location.id; displayName = $name }
    } catch {
        Write-Warning "  ! Named location failed: $_"
        return $null
    }
}

function New-TestCAPolicy($Prefix, $State) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-CAPolicy-$id"

    if ($State.groups.Count -eq 0) {
        Write-Warning "  ! No groups available for CA policy targeting"
        return $null
    }

    $targetGroup = $State.groups | Where-Object { -not $_.roleAssignable } | Select-Object -First 1
    if (-not $targetGroup) { $targetGroup = $State.groups[0] }

    try {
        $policy = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -Body @{
            displayName = $name
            state       = 'enabledForReportingButNotEnforced'
            conditions  = @{
                users = @{
                    includeGroups = @($targetGroup.id)
                }
                applications = @{
                    includeApplications = @('None')
                }
            }
            grantControls = @{
                operator        = 'OR'
                builtInControls = @('mfa')
            }
        }
        Write-Host "  + CA Policy: $name (targeting $($targetGroup.displayName))" -ForegroundColor Green
        return @{ id = $policy.id; displayName = $name; targetGroupId = $targetGroup.id }
    } catch {
        Write-Warning "  ! CA policy failed: $_"
        return $null
    }
}

function Update-TestCAPolicy($PolicyId, $State, $Action) {
    try {
        if ($Action -eq 'AddExclusion' -and $State.users.Count -gt 0) {
            $excludeUser = $State.users | Get-Random
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$PolicyId" -Body @{
                conditions = @{
                    users = @{
                        excludeUsers = @($excludeUser.id)
                    }
                }
            }
            Write-Host "  ~ CA Policy: Added exclusion for $($excludeUser.displayName)" -ForegroundColor Cyan
            return $true
        }
        elseif ($Action -eq 'AddLocation' -and $State.namedLocations.Count -gt 0) {
            $location = $State.namedLocations | Get-Random
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$PolicyId" -Body @{
                conditions = @{
                    locations = @{
                        includeLocations = @($location.id)
                    }
                }
            }
            Write-Host "  ~ CA Policy: Added location condition $($location.displayName)" -ForegroundColor Cyan
            return $true
        }
    } catch {
        Write-Warning "  ! CA policy update failed: $_"
    }
    return $false
}

function New-TestCompliancePolicy($Prefix, $State) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-Compliance-$id"

    try {
        $policy = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies' -Body @{
            '@odata.type'                        = '#microsoft.graph.windows10CompliancePolicy'
            displayName                          = $name
            description                          = 'Alpenglow test compliance policy'
            passwordRequired                     = $false
            passwordBlockSimple                  = $false
            osMinimumVersion                     = $null
            osMaximumVersion                     = $null
            bitLockerEnabled                     = $false
            secureBootEnabled                    = $false
            codeIntegrityEnabled                 = $false
            storageRequireEncryption             = $false
        }
        Write-Host "  + Compliance Policy: $name" -ForegroundColor Green

        if ($State.groups.Count -gt 0) {
            $targetGroup = $State.groups | Where-Object { -not $_.roleAssignable } | Select-Object -First 1
            if ($targetGroup) {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$($policy.id)/assign" -Body @{
                    assignments = @(
                        @{
                            target = @{
                                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                                groupId       = $targetGroup.id
                            }
                        }
                    )
                }
                Write-Host "    -> Assigned to $($targetGroup.displayName)" -ForegroundColor Gray
            }
        }

        return @{ id = $policy.id; displayName = $name }
    } catch {
        Write-Warning "  ! Compliance policy failed: $_"
        return $null
    }
}

function New-TestAppProtectionPolicy($Prefix, $State) {
    $id = (New-Guid).ToString().Substring(0, 8)
    $name = "$Prefix-AppProtection-$id"

    try {
        $policy = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections' -Body @{
            '@odata.type'                  = '#microsoft.graph.iosManagedAppProtection'
            displayName                    = $name
            description                    = 'Alpenglow test app protection policy'
            periodOfflineBeforeAccessCheck = 'PT12H'
            periodOnlineBeforeAccessCheck  = 'PT30M'
            allowedInboundDataTransferSources = 'allApps'
            allowedOutboundDataTransferDestinations = 'allApps'
            organizationalCredentialsRequired = $false
            allowedOutboundClipboardSharingLevel = 'allApps'
            dataBackupBlocked              = $false
            deviceComplianceRequired       = $false
            managedBrowserToOpenLinksRequired = $false
            saveAsBlocked                  = $false
            periodOfflineBeforeWipeIsEnforced = 'P90D'
            pinRequired                    = $false
            disableAppPinIfDevicePinIsSet  = $false
            maximumPinRetries              = 5
            simplePinBlocked               = $false
            minimumPinLength               = 4
            pinCharacterSet                = 'numeric'
            periodBeforePinReset           = 'PT0S'
            allowedDataStorageLocations    = @('oneDriveForBusiness', 'sharePoint')
            contactSyncBlocked             = $false
            printBlocked                   = $false
            fingerprintBlocked             = $false
            appDataEncryptionType          = 'whenDeviceLocked'
        }
        Write-Host "  + App Protection Policy: $name" -ForegroundColor Green

        if ($State.groups.Count -gt 0) {
            $targetGroup = $State.groups | Where-Object { -not $_.roleAssignable } | Select-Object -First 1
            if ($targetGroup) {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$($policy.id)/assign" -Body @{
                    assignments = @(
                        @{
                            target = @{
                                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                                groupId       = $targetGroup.id
                            }
                        }
                    )
                }
                Write-Host "    -> Assigned to $($targetGroup.displayName)" -ForegroundColor Gray
            }
        }

        return @{ id = $policy.id; displayName = $name }
    } catch {
        Write-Warning "  ! App protection policy failed: $_"
        return $null
    }
}

#endregion

#region Azure Resource Functions

function New-TestAzureResources($Prefix, $State, $Caps) {
    if (-not $Caps.HasAzAccess) {
        Write-Host "  [SKIP] Azure resources - not connected" -ForegroundColor Yellow
        return
    }

    $unique = (Get-Random -Maximum 99999)
    $rgName = $Config.AzureRgName
    $location = $Config.AzureLocation
    $tags = @{ Purpose = 'Alpenglow-Test'; ManagedBy = 'Invoke-AlpenglowTestData' }

    Write-Host "`nCreating Azure resources (FREE/cheap tier only)..." -ForegroundColor White

    try {
        # Resource Group (FREE)
        $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        if (-not $rg) {
            $rg = New-AzResourceGroup -Name $rgName -Location $location -Tag $tags
            Write-Host "  + Resource Group: $rgName [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'resourceGroup'; name = $rgName; id = $rg.ResourceId })
        } else {
            Write-Host "  = Resource Group exists: $rgName" -ForegroundColor Gray
        }

        # User-Assigned Managed Identity (FREE)
        $uamiName = "$Prefix-identity-$unique"
        try {
            $uami = New-AzUserAssignedIdentity -ResourceGroupName $rgName -Name $uamiName -Location $location -Tag $tags -ErrorAction Stop
            Write-Host "  + Managed Identity: $uamiName [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'managedIdentity'; name = $uamiName; id = $uami.Id; principalId = $uami.PrincipalId; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Managed identity failed: $_"
        }

        # Storage Account (CHEAP - ~$0.02/GB/month, we use minimal)
        $storageName = "st$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $storageName = $storageName.Substring(0, [Math]::Min(24, $storageName.Length))
        try {
            $storage = New-AzStorageAccount -ResourceGroupName $rgName -Name $storageName -Location $location -SkuName 'Standard_LRS' -Kind 'StorageV2' -Tag $tags -ErrorAction Stop
            Write-Host "  + Storage Account: $storageName [CHEAP]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'storageAccount'; name = $storageName; id = $storage.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Storage account failed: $_"
        }

        # Automation Account (FREE tier)
        $autoName = "aa-$Prefix-$unique".Substring(0, [Math]::Min(50, "aa-$Prefix-$unique".Length))
        try {
            $auto = New-AzAutomationAccount -ResourceGroupName $rgName -Name $autoName -Location $location -Tag $tags -Plan Free -ErrorAction Stop
            Write-Host "  + Automation Account: $autoName [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'automationAccount'; name = $autoName; id = $auto.AutomationAccountId; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Automation account failed: $_"
        }

        # App Service Plan + Web App (FREE tier with system-assigned managed identity)
        $planName = "asp-$Prefix-$unique".Substring(0, [Math]::Min(40, "asp-$Prefix-$unique".Length))
        $webAppName = "web$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $webAppName = $webAppName.Substring(0, [Math]::Min(60, $webAppName.Length))
        try {
            $plan = New-AzAppServicePlan -ResourceGroupName $rgName -Name $planName -Location $location -Tier Free -Tag $tags -ErrorAction Stop
            Write-Host "  + App Service Plan: $planName [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'appServicePlan'; name = $planName; id = $plan.Id; resourceGroup = $rgName })

            $webApp = New-AzWebApp -ResourceGroupName $rgName -Name $webAppName -Location $location -AppServicePlan $planName -Tag $tags -ErrorAction Stop
            # Enable system-assigned managed identity (FREE - creates SP for detection testing)
            Set-AzWebApp -ResourceGroupName $rgName -Name $webAppName -AssignIdentity $true | Out-Null
            Write-Host "  + Web App: $webAppName (with managed identity) [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'webApp'; name = $webAppName; id = $webApp.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Web App failed: $_"
        }

        # Key Vault (pay per operation - essentially free for testing)
        $kvName = "kv$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $kvName = $kvName.Substring(0, [Math]::Min(24, $kvName.Length))
        try {
            $kv = New-AzKeyVault -ResourceGroupName $rgName -VaultName $kvName -Location $location -EnableRbacAuthorization -Tag $tags -ErrorAction Stop
            Write-Host "  + Key Vault: $kvName [PAY-PER-OP]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'keyVault'; name = $kvName; id = $kv.ResourceId; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Key Vault failed: $_"
        }

        # Function App (Consumption plan - FREE when idle)
        $funcAppName = "func$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $funcAppName = $funcAppName.Substring(0, [Math]::Min(60, $funcAppName.Length))
        try {
            # Consumption plan is created automatically with -FunctionsVersion
            $funcApp = New-AzFunctionApp -ResourceGroupName $rgName -Name $funcAppName -Location $location -StorageAccountName $storageName -Runtime PowerShell -FunctionsVersion 4 -OSType Windows -Tag $tags -ErrorAction Stop
            # Enable managed identity
            Update-AzFunctionApp -ResourceGroupName $rgName -Name $funcAppName -IdentityType SystemAssigned -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  + Function App: $funcAppName (Consumption) [FREE IDLE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'functionApp'; name = $funcAppName; id = $funcApp.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Function App failed: $_"
        }

        # Logic App (Consumption - pay per action, free when disabled)
        $logicAppName = "logic-$Prefix-$unique".Substring(0, [Math]::Min(43, "logic-$Prefix-$unique".Length))
        try {
            # Create minimal disabled Logic App via ARM
            $logicAppDef = @{
                location = $location
                tags = $tags
                properties = @{
                    state = 'Disabled'
                    definition = @{
                        '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
                        contentVersion = '1.0.0.0'
                        triggers = @{}
                        actions = @{}
                    }
                }
                identity = @{ type = 'SystemAssigned' }
            }
            $logicApp = New-AzResource -ResourceGroupName $rgName -ResourceType 'Microsoft.Logic/workflows' -ResourceName $logicAppName -ApiVersion '2019-05-01' -Properties $logicAppDef.properties -Location $location -Tag $tags -Force -ErrorAction Stop
            Write-Host "  + Logic App: $logicAppName (Disabled) [FREE]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'logicApp'; name = $logicAppName; id = $logicApp.ResourceId; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Logic App failed: $_"
        }

        # Container Registry (Basic SKU - ~$5/month)
        $acrName = "acr$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $acrName = $acrName.Substring(0, [Math]::Min(50, $acrName.Length))
        try {
            $acr = New-AzContainerRegistry -ResourceGroupName $rgName -Name $acrName -Location $location -Sku Basic -Tag $tags -ErrorAction Stop
            Write-Host "  + Container Registry: $acrName (Basic) [~`$5/mo]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'containerRegistry'; name = $acrName; id = $acr.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Container Registry failed: $_"
        }

        # Virtual Machine (B1ls - cheapest ~$3.80/month)
        $vmName = "vm$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $vmName = $vmName.Substring(0, [Math]::Min(15, $vmName.Length))
        try {
            $vmCred = New-Object System.Management.Automation.PSCredential('azureuser', (ConvertTo-SecureString 'P@ssw0rd1234!' -AsPlainText -Force))
            New-AzVM -ResourceGroupName $rgName -Name $vmName -Location $location -Image 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest' -Size 'Standard_B1ls' -Credential $vmCred -Tag $tags -StorageAccountType 'Standard_LRS' -ErrorAction Stop | Out-Null
            # Enable managed identity
            $vmObj = Get-AzVM -ResourceGroupName $rgName -Name $vmName
            Update-AzVM -ResourceGroupName $rgName -VM $vmObj -IdentityType SystemAssigned -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  + Virtual Machine: $vmName (B1ls) [CHEAP]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'virtualMachine'; name = $vmName; id = $vmObj.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! Virtual Machine failed: $_"
        }

        # AKS Cluster (Free tier, 1 node - takes ~5-7 mins)
        $aksName = "aks$($Prefix.ToLower() -replace '[^a-z0-9]', '')$unique"
        $aksName = $aksName.Substring(0, [Math]::Min(63, $aksName.Length))
        try {
            Write-Host "  * Creating AKS (takes ~5-7 mins)..." -ForegroundColor Gray
            New-AzAksCluster -ResourceGroupName $rgName -Name $aksName -Location $location -NodeCount 1 -NodeVmSize 'Standard_B2s' -SkuTier Free -GenerateSshKey -Tag $tags -ErrorAction Stop | Out-Null
            $aks = Get-AzAksCluster -ResourceGroupName $rgName -Name $aksName
            Write-Host "  + AKS Cluster: $aksName (Free tier, 1 node) [CHEAP]" -ForegroundColor Green
            $null = $State.azureResources.Add(@{ type = 'aksCluster'; name = $aksName; id = $aks.Id; resourceGroup = $rgName })
        } catch {
            Write-Warning "  ! AKS Cluster failed: $_"
        }

        # NOTE: Skipping VMSS and DataFactory (no cheap placeholder option)
        Write-Host "  [INFO] Skipped: VMSS, DataFactory (no cheap option)" -ForegroundColor Gray

    } catch {
        Write-Warning "  ! Azure resource creation failed: $_"
    }
}

function Update-TestAzureResources($State, $Caps) {
    if (-not $Caps.HasAzAccess -or $State.azureResources.Count -eq 0) {
        return 0
    }

    $changes = 0
    Write-Host "`nModifying Azure resources..." -ForegroundColor White

    # Randomly choose change magnitude
    $magnitude = @('small', 'medium', 'major') | Get-Random
    Write-Host "  [Simulating $magnitude changes]" -ForegroundColor Gray

    # Update Web App settings (simulates config changes)
    $webApp = $State.azureResources | Where-Object { $_.type -eq 'webApp' } | Select-Object -First 1
    if ($webApp) {
        try {
            $appSettings = @{
                'ALPENGLOW_TEST_TIMESTAMP' = (Get-Date -Format 'o')
                'ALPENGLOW_CHANGE_TYPE' = $magnitude
                'ALPENGLOW_RUN_ID' = (New-Guid).ToString().Substring(0, 8)
            }

            if ($magnitude -eq 'medium' -or $magnitude -eq 'major') {
                $appSettings['ALPENGLOW_CONFIG_VERSION'] = "v$(Get-Random -Maximum 100)"
            }

            Set-AzWebApp -ResourceGroupName $webApp.resourceGroup -Name $webApp.name -AppSettings $appSettings | Out-Null
            Write-Host "  ~ Updated $($appSettings.Count) app settings on $($webApp.name)" -ForegroundColor Cyan
            $changes++
        } catch {
            Write-Warning "  ! Web App update failed: $_"
        }
    }

    # Update Storage Account tags (simulates metadata changes)
    $storage = $State.azureResources | Where-Object { $_.type -eq 'storageAccount' } | Select-Object -First 1
    if ($storage -and ($magnitude -eq 'medium' -or $magnitude -eq 'major')) {
        try {
            $newTags = @{
                Purpose = 'Alpenglow-Test'
                ManagedBy = 'Invoke-AlpenglowTestData'
                LastModified = (Get-Date -Format 'yyyy-MM-dd')
                ChangeType = $magnitude
            }
            Set-AzStorageAccount -ResourceGroupName $storage.resourceGroup -Name $storage.name -Tag $newTags | Out-Null
            Write-Host "  ~ Updated tags on $($storage.name)" -ForegroundColor Cyan
            $changes++
        } catch {
            Write-Warning "  ! Storage tag update failed: $_"
        }
    }

    # Major change: Toggle managed identity on web app
    if ($magnitude -eq 'major' -and $webApp) {
        try {
            # Disable then re-enable (creates new SP - simulates identity rotation)
            Set-AzWebApp -ResourceGroupName $webApp.resourceGroup -Name $webApp.name -AssignIdentity $false | Out-Null
            Start-Sleep -Seconds 2
            Set-AzWebApp -ResourceGroupName $webApp.resourceGroup -Name $webApp.name -AssignIdentity $true | Out-Null
            Write-Host "  ~ Rotated managed identity on $($webApp.name) (MAJOR)" -ForegroundColor Magenta
            $changes++
        } catch {
            Write-Warning "  ! Managed identity rotation failed: $_"
        }
    }

    return $changes
}

function Remove-TestAzureResources($State, $Caps) {
    if (-not $Caps.HasAzAccess -or $State.azureResources.Count -eq 0) {
        return
    }

    Write-Host "`nDeleting Azure resources..." -ForegroundColor White

    # Delete the resource group (which deletes everything in it)
    $rg = $State.azureResources | Where-Object { $_.type -eq 'resourceGroup' } | Select-Object -First 1
    if ($rg) {
        try {
            Write-Host "  - Deleting Resource Group: $($rg.name) (this may take a few minutes)..." -ForegroundColor Yellow
            Remove-AzResourceGroup -Name $rg.name -Force -ErrorAction Stop | Out-Null
            Write-Host "  - Resource Group deleted (and all contents)" -ForegroundColor Yellow
        } catch {
            if ($_.Exception.Message -notmatch 'not found') {
                Write-Warning "  ! Failed to delete RG: $_"
            }
        }
    }
}

#endregion

#region Main Actions

function Invoke-Create {
    param($State, $Caps, $Prefix)

    Write-Host "`n=== Creating Test Objects ===" -ForegroundColor Cyan

    # Create users
    Write-Host "`nCreating $($Config.UserCount) users..." -ForegroundColor White
    for ($i = 1; $i -le $Config.UserCount; $i++) {
        $user = New-TestUser -Prefix $Prefix -Suffix "U$i" -Domain $Caps.TenantDomain
        if ($user) { $null = $State.users.Add($user) }
    }

    # Create groups
    Write-Host "`nCreating $($Config.GroupCount) groups..." -ForegroundColor White
    for ($i = 1; $i -le $Config.GroupCount; $i++) {
        $group = New-TestGroup -Prefix $Prefix -Suffix "G$i"
        if ($group) { $null = $State.groups.Add($group) }
    }

    # Create nested group chain
    Write-Host "`nCreating nested group chain ($($Config.NestingDepth) levels)..." -ForegroundColor White
    $prevGroupId = $null
    for ($i = 1; $i -le $Config.NestingDepth; $i++) {
        $group = New-TestGroup -Prefix $Prefix -Suffix "Nest-L$i"
        if ($group) {
            $null = $State.groups.Add($group)
            if ($prevGroupId) { Add-GroupMember -GroupId $prevGroupId -MemberId $group.id | Out-Null }
            $prevGroupId = $group.id
        }
    }
    if ($prevGroupId -and $State.users.Count -gt 0) {
        Add-GroupMember -GroupId $prevGroupId -MemberId $State.users[0].id | Out-Null
        Write-Host "  + Added user to innermost nested group" -ForegroundColor Green
    }

    # Create role-assignable group (if PIM available)
    if ($Caps.HasPIM) {
        Write-Host "`nCreating role-assignable group..." -ForegroundColor White
        $rag = New-TestGroup -Prefix $Prefix -Suffix "RoleAssign" -RoleAssignable
        if ($rag) { $null = $State.groups.Add($rag) }
    }

    # Create apps
    Write-Host "`nCreating $($Config.AppCount) applications..." -ForegroundColor White
    for ($i = 1; $i -le $Config.AppCount; $i++) {
        $app = New-TestApp -Prefix $Prefix -Suffix "App$i"
        if ($app) {
            $null = $State.apps.Add($app)
            $keyId = Add-Credential -SpId $app.spId
            if ($keyId) {
                $null = $State.credentials.Add(@{ spId = $app.spId; keyId = $keyId })
                Write-Host "  + Added credential to $($app.displayName)" -ForegroundColor Green
            }
        }
    }

    # Add memberships
    Write-Host "`nCreating group memberships..." -ForegroundColor White
    $regularGroups = @($State.groups | Where-Object { -not $_.roleAssignable -and $_.displayName -notmatch 'Nest-L' })
    foreach ($user in $State.users | Select-Object -First 5) {
        $group = $regularGroups | Get-Random
        if ($group -and (Add-GroupMember -GroupId $group.id -MemberId $user.id)) {
            $null = $State.memberships.Add(@{ groupId = $group.id; memberId = $user.id })
            Write-Host "  + Added $($user.displayName) to $($group.displayName)" -ForegroundColor Green
        }
    }

    # Add PIM eligibility
    if ($Caps.HasPIM -and $State.users.Count -gt 0) {
        Write-Host "`nCreating PIM eligibility..." -ForegroundColor White
        $user = $State.users[0]
        if (Add-PimEligibility -PrincipalId $user.id -RoleId $RoleDefinitions.HelpDeskAdmin) {
            Write-Host "  + PIM eligible: $($user.displayName) -> Help Desk Admin" -ForegroundColor Green
        }
    } elseif (-not $Caps.HasPIM) {
        Write-Host "`n  [SKIP] PIM not available" -ForegroundColor Yellow
    }

    # Add direct role assignments (non-PIM)
    if ($State.users.Count -gt 1) {
        Write-Host "`nCreating direct role assignments..." -ForegroundColor White
        $roleUser = $State.users | Select-Object -Skip 1 | Select-Object -First 1
        if ($roleUser) {
            $assignmentId = Add-DirectRoleAssignment -PrincipalId $roleUser.id -RoleId $RoleDefinitions.SecurityReader
            if ($assignmentId) {
                $null = $State.directRoleAssignments.Add(@{ id = $assignmentId; principalId = $roleUser.id; roleId = $RoleDefinitions.SecurityReader; roleName = 'SecurityReader' })
                Write-Host "  + Direct role: $($roleUser.displayName) -> Security Reader" -ForegroundColor Green
            }
        }
    }

    # Add group ownerships
    if ($State.users.Count -gt 0 -and $State.groups.Count -gt 0) {
        Write-Host "`nCreating group ownerships..." -ForegroundColor White
        $regularGroups = @($State.groups | Where-Object { -not $_.roleAssignable -and $_.displayName -notmatch 'Nest-L' })
        foreach ($group in $regularGroups | Select-Object -First 2) {
            $owner = $State.users | Get-Random
            if ($owner -and (Add-GroupOwner -GroupId $group.id -OwnerId $owner.id)) {
                $null = $State.groupOwnerships.Add(@{ groupId = $group.id; ownerId = $owner.id })
                Write-Host "  + Owner: $($owner.displayName) -> $($group.displayName)" -ForegroundColor Green
            }
        }
    }

    # Add app/SP ownerships
    if ($State.users.Count -gt 0 -and $State.apps.Count -gt 0) {
        Write-Host "`nCreating app/SP ownerships..." -ForegroundColor White
        foreach ($app in $State.apps | Select-Object -First 2) {
            $owner = $State.users | Get-Random
            if ($owner) {
                # App owner
                if (Add-AppOwner -AppId $app.appId -OwnerId $owner.id) {
                    $null = $State.appOwnerships.Add(@{ appId = $app.appId; ownerId = $owner.id })
                    Write-Host "  + App owner: $($owner.displayName) -> $($app.displayName)" -ForegroundColor Green
                }
                # SP owner (different user for variety)
                $spOwner = $State.users | Where-Object { $_.id -ne $owner.id } | Get-Random
                if ($spOwner -and (Add-SpOwner -SpId $app.spId -OwnerId $spOwner.id)) {
                    $null = $State.spOwnerships.Add(@{ spId = $app.spId; ownerId = $spOwner.id })
                    Write-Host "  + SP owner: $($spOwner.displayName) -> $($app.displayName)" -ForegroundColor Green
                }
            }
        }
    }

    # Create Named Locations
    if ($Caps.HasCA) {
        Write-Host "`nCreating named locations..." -ForegroundColor White
        for ($i = 1; $i -le 2; $i++) {
            $loc = New-TestNamedLocation -Prefix $Prefix
            if ($loc) { $null = $State.namedLocations.Add($loc) }
        }
    } else {
        Write-Host "`n  [SKIP] Named locations - CA not available" -ForegroundColor Yellow
    }

    # Create CA Policies
    if ($Caps.HasCA -and $State.groups.Count -gt 0) {
        Write-Host "`nCreating CA policies..." -ForegroundColor White
        for ($i = 1; $i -le 2; $i++) {
            $policy = New-TestCAPolicy -Prefix $Prefix -State $State
            if ($policy) { $null = $State.caPolicies.Add($policy) }
        }
    } elseif (-not $Caps.HasCA) {
        Write-Host "`n  [SKIP] CA policies - not available" -ForegroundColor Yellow
    }

    # Create Compliance Policies
    if ($Caps.HasIntune) {
        Write-Host "`nCreating Intune compliance policies..." -ForegroundColor White
        $compPolicy = New-TestCompliancePolicy -Prefix $Prefix -State $State
        if ($compPolicy) { $null = $State.compliancePolicies.Add($compPolicy) }
    } else {
        Write-Host "`n  [SKIP] Compliance policies - Intune not available" -ForegroundColor Yellow
    }

    # Create App Protection Policies
    if ($Caps.HasIntune) {
        Write-Host "`nCreating Intune app protection policies..." -ForegroundColor White
        $appPolicy = New-TestAppProtectionPolicy -Prefix $Prefix -State $State
        if ($appPolicy) { $null = $State.appProtectionPolicies.Add($appPolicy) }
    } else {
        Write-Host "`n  [SKIP] App protection policies - Intune not available" -ForegroundColor Yellow
    }

    # Create Azure Resources
    if ($Caps.HasAzModule) {
        if (Connect-ToAzure -Caps $Caps) {
            $Caps.HasAzAccess = $true
            New-TestAzureResources -Prefix $Prefix -State $State -Caps $Caps
        }
    } else {
        Write-Host "`n  [SKIP] Azure resources - Az module not installed" -ForegroundColor Yellow
    }

    Write-Host "`n=== Creation Complete ===" -ForegroundColor Cyan
    Write-Host "  Users: $($State.users.Count)" -ForegroundColor Gray
    Write-Host "  Groups: $($State.groups.Count)" -ForegroundColor Gray
    Write-Host "  Apps: $($State.apps.Count)" -ForegroundColor Gray
    Write-Host "  Memberships: $($State.memberships.Count)" -ForegroundColor Gray
    Write-Host "  Group Ownerships: $($State.groupOwnerships.Count)" -ForegroundColor Gray
    Write-Host "  App Ownerships: $($State.appOwnerships.Count)" -ForegroundColor Gray
    Write-Host "  SP Ownerships: $($State.spOwnerships.Count)" -ForegroundColor Gray
    Write-Host "  Direct Role Assignments: $($State.directRoleAssignments.Count)" -ForegroundColor Gray
    Write-Host "  Named Locations: $($State.namedLocations.Count)" -ForegroundColor Gray
    Write-Host "  CA Policies: $($State.caPolicies.Count)" -ForegroundColor Gray
    Write-Host "  Compliance Policies: $($State.compliancePolicies.Count)" -ForegroundColor Gray
    Write-Host "  App Protection Policies: $($State.appProtectionPolicies.Count)" -ForegroundColor Gray
    Write-Host "  Azure Resources: $($State.azureResources.Count)" -ForegroundColor Gray
}

function Invoke-Changes {
    param($State, $Caps)

    Write-Host "`n=== Making Random Changes ===" -ForegroundColor Cyan
    $changes = 0

    # 1. Add some new memberships
    Write-Host "`nAdding new memberships..." -ForegroundColor White
    $regularGroups = @($State.groups | Where-Object { -not $_.roleAssignable -and $_.displayName -notmatch 'Nest-L' })
    $usersNotInGroups = @($State.users | Where-Object { $id = $_.id; $State.memberships.memberId -notcontains $id })

    foreach ($user in $usersNotInGroups | Get-Random -Count ([Math]::Min(3, $usersNotInGroups.Count))) {
        $group = $regularGroups | Get-Random
        if ($group -and (Add-GroupMember -GroupId $group.id -MemberId $user.id)) {
            $null = $State.memberships.Add(@{ groupId = $group.id; memberId = $user.id })
            Write-Host "  + Added $($user.displayName) to $($group.displayName)" -ForegroundColor Green
            $changes++
        }
    }

    # 2. Remove some memberships
    Write-Host "`nRemoving some memberships..." -ForegroundColor White
    $toRemove = @($State.memberships | Get-Random -Count ([Math]::Min(2, [Math]::Max(0, $State.memberships.Count - 2))))
    foreach ($m in $toRemove) {
        if (Remove-GroupMember -GroupId $m.groupId -MemberId $m.memberId) {
            $user = $State.users | Where-Object { $_.id -eq $m.memberId }
            $group = $State.groups | Where-Object { $_.id -eq $m.groupId }
            Write-Host "  - Removed $($user.displayName) from $($group.displayName)" -ForegroundColor Yellow
            $State.memberships.Remove($m)
            $changes++
        }
    }

    # 3. Rotate credentials
    Write-Host "`nRotating credentials..." -ForegroundColor White
    foreach ($app in $State.apps | Get-Random -Count ([Math]::Min(2, $State.apps.Count))) {
        $newKeyId = Add-Credential -SpId $app.spId
        if ($newKeyId) {
            $null = $State.credentials.Add(@{ spId = $app.spId; keyId = $newKeyId })
            Write-Host "  + Added new credential to $($app.displayName)" -ForegroundColor Green
            $changes++
        }

        $appCreds = @($State.credentials | Where-Object { $_.spId -eq $app.spId })
        if ($appCreds.Count -gt 1) {
            $oldCred = $appCreds | Select-Object -First 1
            if (Remove-Credential -SpId $app.spId -KeyId $oldCred.keyId) {
                $State.credentials.Remove($oldCred)
                Write-Host "  - Removed old credential from $($app.displayName)" -ForegroundColor Yellow
                $changes++
            }
        }
    }

    # 4. Enable/disable users
    Write-Host "`nToggling user accounts..." -ForegroundColor White
    $toggleUser = $State.users | Get-Random
    if ($toggleUser) {
        try {
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($toggleUser.id)" -Body @{ accountEnabled = $false }
            Write-Host "  ~ Disabled $($toggleUser.displayName)" -ForegroundColor Cyan
            $changes++

            Start-Sleep -Milliseconds 500

            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($toggleUser.id)" -Body @{ accountEnabled = $true }
            Write-Host "  ~ Re-enabled $($toggleUser.displayName)" -ForegroundColor Cyan
            $changes++
        } catch {
            Write-Warning "  ! Toggle failed: $_"
        }
    }

    # 5. Revoke sessions
    Write-Host "`nRevoking user sessions..." -ForegroundColor White
    $revokeUser = $State.users | Get-Random
    if ($revokeUser) {
        try {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$($revokeUser.id)/revokeSignInSessions"
            Write-Host "  ~ Revoked sessions for $($revokeUser.displayName)" -ForegroundColor Cyan
            $changes++
        } catch {
            Write-Warning "  ! Revoke failed: $_"
        }
    }

    # 6. PIM changes
    if ($Caps.HasPIM -and $State.users.Count -gt 1) {
        Write-Host "`nMaking PIM changes..." -ForegroundColor White
        $pimUser = $State.users | Select-Object -Skip 1 | Get-Random
        if ($pimUser -and (Add-PimEligibility -PrincipalId $pimUser.id -RoleId $RoleDefinitions.SecurityReader)) {
            Write-Host "  + PIM eligible: $($pimUser.displayName) -> Security Reader" -ForegroundColor Green
            $changes++
        }
    } elseif (-not $Caps.HasPIM) {
        Write-Host "`n  [SKIP] PIM changes - not available" -ForegroundColor Yellow
    }

    # 7. Ownership changes
    Write-Host "`nModifying ownerships..." -ForegroundColor White

    # Add/remove group owners
    if ($State.groups.Count -gt 0 -and $State.users.Count -gt 1) {
        $regularGroups = @($State.groups | Where-Object { -not $_.roleAssignable -and $_.displayName -notmatch 'Nest-L' })
        if ($regularGroups.Count -gt 0) {
            # Add a new group owner
            $targetGroup = $regularGroups | Get-Random
            $newOwner = $State.users | Where-Object { $id = $_.id; $State.groupOwnerships | Where-Object { $_.groupId -eq $targetGroup.id -and $_.ownerId -eq $id } | Measure-Object | ForEach-Object { $_.Count -eq 0 } } | Get-Random
            if ($targetGroup -and $newOwner -and (Add-GroupOwner -GroupId $targetGroup.id -OwnerId $newOwner.id)) {
                $null = $State.groupOwnerships.Add(@{ groupId = $targetGroup.id; ownerId = $newOwner.id })
                Write-Host "  + Group owner: $($newOwner.displayName) -> $($targetGroup.displayName)" -ForegroundColor Green
                $changes++
            }

            # Remove a group owner (if we have more than one)
            $ownerToRemove = $State.groupOwnerships | Get-Random
            if ($ownerToRemove -and ($State.groupOwnerships | Where-Object { $_.groupId -eq $ownerToRemove.groupId } | Measure-Object).Count -gt 1) {
                if (Remove-GroupOwner -GroupId $ownerToRemove.groupId -OwnerId $ownerToRemove.ownerId) {
                    $owner = $State.users | Where-Object { $_.id -eq $ownerToRemove.ownerId }
                    $group = $State.groups | Where-Object { $_.id -eq $ownerToRemove.groupId }
                    Write-Host "  - Removed group owner: $($owner.displayName) from $($group.displayName)" -ForegroundColor Yellow
                    $State.groupOwnerships.Remove($ownerToRemove)
                    $changes++
                }
            }
        }
    }

    # Add/remove app owners
    if ($State.apps.Count -gt 0 -and $State.users.Count -gt 1) {
        $targetApp = $State.apps | Get-Random
        $newAppOwner = $State.users | Where-Object { $id = $_.id; $State.appOwnerships | Where-Object { $_.appId -eq $targetApp.appId -and $_.ownerId -eq $id } | Measure-Object | ForEach-Object { $_.Count -eq 0 } } | Get-Random
        if ($targetApp -and $newAppOwner -and (Add-AppOwner -AppId $targetApp.appId -OwnerId $newAppOwner.id)) {
            $null = $State.appOwnerships.Add(@{ appId = $targetApp.appId; ownerId = $newAppOwner.id })
            Write-Host "  + App owner: $($newAppOwner.displayName) -> $($targetApp.displayName)" -ForegroundColor Green
            $changes++
        }
    }

    # Add/remove SP owners
    if ($State.apps.Count -gt 0 -and $State.users.Count -gt 1) {
        $targetApp = $State.apps | Get-Random
        $newSpOwner = $State.users | Where-Object { $id = $_.id; $State.spOwnerships | Where-Object { $_.spId -eq $targetApp.spId -and $_.ownerId -eq $id } | Measure-Object | ForEach-Object { $_.Count -eq 0 } } | Get-Random
        if ($targetApp -and $newSpOwner -and (Add-SpOwner -SpId $targetApp.spId -OwnerId $newSpOwner.id)) {
            $null = $State.spOwnerships.Add(@{ spId = $targetApp.spId; ownerId = $newSpOwner.id })
            Write-Host "  + SP owner: $($newSpOwner.displayName) -> $($targetApp.displayName)" -ForegroundColor Green
            $changes++
        }
    }

    # 8. Direct role assignment changes
    if ($State.users.Count -gt 2) {
        Write-Host "`nModifying direct role assignments..." -ForegroundColor White
        # Add a new direct role assignment
        $eligibleUsers = @($State.users | Where-Object { $id = $_.id; $State.directRoleAssignments | Where-Object { $_.principalId -eq $id } | Measure-Object | ForEach-Object { $_.Count -eq 0 } })
        if ($eligibleUsers.Count -gt 0) {
            $newRoleUser = $eligibleUsers | Get-Random
            $roleToAssign = @('GroupsAdmin', 'SecurityReader', 'HelpDeskAdmin') | Get-Random
            $assignmentId = Add-DirectRoleAssignment -PrincipalId $newRoleUser.id -RoleId $RoleDefinitions[$roleToAssign]
            if ($assignmentId) {
                $null = $State.directRoleAssignments.Add(@{ id = $assignmentId; principalId = $newRoleUser.id; roleId = $RoleDefinitions[$roleToAssign]; roleName = $roleToAssign })
                Write-Host "  + Direct role: $($newRoleUser.displayName) -> $roleToAssign" -ForegroundColor Green
                $changes++
            }
        }

        # Remove a direct role assignment (if we have multiple)
        if ($State.directRoleAssignments.Count -gt 1) {
            $assignmentToRemove = $State.directRoleAssignments | Get-Random
            if ($assignmentToRemove -and (Remove-DirectRoleAssignment -AssignmentId $assignmentToRemove.id)) {
                $user = $State.users | Where-Object { $_.id -eq $assignmentToRemove.principalId }
                Write-Host "  - Removed direct role: $($user.displayName) -> $($assignmentToRemove.roleName)" -ForegroundColor Yellow
                $State.directRoleAssignments.Remove($assignmentToRemove)
                $changes++
            }
        }
    }

    # 9. CA Policy changes
    if ($Caps.HasCA -and $State.caPolicies.Count -gt 0) {
        Write-Host "`nModifying CA policies..." -ForegroundColor White
        $policy = $State.caPolicies | Get-Random
        if ($policy) {
            $action = @('AddExclusion', 'AddLocation') | Get-Random
            if (Update-TestCAPolicy -PolicyId $policy.id -State $State -Action $action) {
                $changes++
            }
        }
    } elseif (-not $Caps.HasCA) {
        Write-Host "`n  [SKIP] CA policy changes - not available" -ForegroundColor Yellow
    }

    # 10. Azure resource changes
    if ($Caps.HasAzModule) {
        if (Connect-ToAzure -Caps $Caps) {
            $Caps.HasAzAccess = $true
            $changes += Update-TestAzureResources -State $State -Caps $Caps
        }
    }

    Write-Host "`n=== Changes Complete: $changes modifications ===" -ForegroundColor Cyan
}

function Invoke-Cleanup {
    param($State, $Caps)

    Write-Host "`n=== Cleaning Up Test Objects ===" -ForegroundColor Yellow
    $deleted = @{ users = 0; groups = 0; apps = 0; policies = 0; azure = 0; skipped = 0 }

    # Delete CA Policies
    Write-Host "`nDeleting CA policies..." -ForegroundColor White
    foreach ($policy in $State.caPolicies) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($policy.id)" -ErrorAction Stop
            Write-Host "  - $($policy.displayName)" -ForegroundColor Yellow
            $deleted.policies++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|not found') { Write-Warning "  ! Failed: $($policy.displayName)" }
        }
    }

    # Delete Named Locations
    Write-Host "`nDeleting named locations..." -ForegroundColor White
    foreach ($loc in $State.namedLocations) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations/$($loc.id)" -ErrorAction Stop
            Write-Host "  - $($loc.displayName)" -ForegroundColor Yellow
            $deleted.policies++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|not found') { Write-Warning "  ! Failed: $($loc.displayName)" }
        }
    }

    # Delete Compliance Policies
    Write-Host "`nDeleting compliance policies..." -ForegroundColor White
    foreach ($policy in $State.compliancePolicies) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$($policy.id)" -ErrorAction Stop
            Write-Host "  - $($policy.displayName)" -ForegroundColor Yellow
            $deleted.policies++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|not found') { Write-Warning "  ! Failed: $($policy.displayName)" }
        }
    }

    # Delete App Protection Policies
    Write-Host "`nDeleting app protection policies..." -ForegroundColor White
    foreach ($policy in $State.appProtectionPolicies) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$($policy.id)" -ErrorAction Stop
            Write-Host "  - $($policy.displayName)" -ForegroundColor Yellow
            $deleted.policies++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|not found') { Write-Warning "  ! Failed: $($policy.displayName)" }
        }
    }

    # Delete direct role assignments (before users/groups)
    Write-Host "`nDeleting direct role assignments..." -ForegroundColor White
    foreach ($assignment in $State.directRoleAssignments) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments/$($assignment.id)" -ErrorAction Stop
            $user = $State.users | Where-Object { $_.id -eq $assignment.principalId }
            Write-Host "  - $($user.displayName) -> $($assignment.roleName)" -ForegroundColor Yellow
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|not found') { Write-Warning "  ! Failed: $($assignment.roleName)" }
        }
    }

    # Delete users
    Write-Host "`nDeleting users..." -ForegroundColor White
    foreach ($user in $State.users) {
        if (Test-IsExcluded -UserId $user.id) {
            Write-Host "  [PROTECTED] $($user.displayName) - member of $ExclusionGroupName" -ForegroundColor Red
            $deleted.skipped++
            continue
        }

        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)" -ErrorAction Stop
            Write-Host "  - $($user.displayName)" -ForegroundColor Yellow
            $deleted.users++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist') { Write-Warning "  ! Failed: $($user.displayName)" }
        }
    }

    # Delete groups
    Write-Host "`nDeleting groups..." -ForegroundColor White
    foreach ($group in $State.groups) {
        if (Test-IsExcludedGroup -GroupId $group.id) {
            Write-Host "  [PROTECTED] $($group.displayName) - exclusion group" -ForegroundColor Red
            $deleted.skipped++
            continue
        }

        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)" -ErrorAction Stop
            Write-Host "  - $($group.displayName)" -ForegroundColor Yellow
            $deleted.groups++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist') { Write-Warning "  ! Failed: $($group.displayName)" }
        }
    }

    # Delete applications
    Write-Host "`nDeleting applications..." -ForegroundColor White
    foreach ($app in $State.apps) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/applications/$($app.appId)" -ErrorAction Stop
            Write-Host "  - $($app.displayName)" -ForegroundColor Yellow
            $deleted.apps++
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist') { Write-Warning "  ! Failed: $($app.displayName)" }
        }
    }

    # Delete Azure resources
    if ($Caps.HasAzModule -and $State.azureResources.Count -gt 0) {
        if (Connect-ToAzure -Caps $Caps) {
            $Caps.HasAzAccess = $true
            Remove-TestAzureResources -State $State -Caps $Caps
            $deleted.azure = $State.azureResources.Count
        }
    }

    # Clear state
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue

    Write-Host "`n=== Cleanup Complete ===" -ForegroundColor Cyan
    Write-Host "  Users: $($deleted.users), Groups: $($deleted.groups), Apps: $($deleted.apps)" -ForegroundColor Gray
    Write-Host "  Policies: $($deleted.policies), Azure: $($deleted.azure), Skipped: $($deleted.skipped)" -ForegroundColor Gray
}

#endregion

#region Main

try {
    # Connect
    Connect-ToGraph

    # CRITICAL: Load exclusion list FIRST
    Initialize-ExclusionList

    # Get capabilities
    $Caps = Get-TenantCapabilities

    # Load state
    $State = Get-State

    # Show banner
    $pim = if ($Caps.HasPIM) { "PIM [Y]" } else { "PIM [N]" }
    $ca = if ($Caps.HasCA) { "CA [Y]" } else { "CA [N]" }
    $intune = if ($Caps.HasIntune) { "Intune [Y]" } else { "Intune [N]" }
    $az = if ($Caps.HasAzModule) { "Az [Y]" } else { "Az [N]" }

    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor Magenta
    Write-Host "   Alpenglow Test Data Generator" -ForegroundColor White
    Write-Host "  ================================================" -ForegroundColor Magenta
    Write-Host "   Tenant: $($Caps.TenantDomain)" -ForegroundColor Gray
    Write-Host "   Features: $pim  $ca  $intune  $az" -ForegroundColor Gray
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

    if ($State.users.Count -eq 0) {
        Write-Host "   Status: No test data exists" -ForegroundColor Yellow
    } else {
        $azCount = if ($State.azureResources.Count -gt 0) { ", $($State.azureResources.Count) Azure" } else { "" }
        Write-Host "   Status: $($State.users.Count) users, $($State.groups.Count) groups, $($State.apps.Count) apps$azCount" -ForegroundColor Green
        if ($State.caPolicies.Count -gt 0 -or $State.compliancePolicies.Count -gt 0) {
            Write-Host "           $($State.caPolicies.Count) CA policies, $($State.compliancePolicies.Count) compliance, $($State.appProtectionPolicies.Count) app protection" -ForegroundColor Green
        }
    }
    Write-Host "  ================================================" -ForegroundColor Magenta

    # Determine action
    if ($NonInteractive -and $Action) {
        $choice = switch ($Action) {
            'Create' { '1' }
            'Changes' { '2' }
            'Cleanup' { '3' }
        }
    } else {
        Write-Host ""
        if ($State.users.Count -eq 0) {
            Write-Host "   [1] Create test objects" -ForegroundColor White
        } else {
            Write-Host "   [1] Create more test objects" -ForegroundColor White
            Write-Host "   [2] Make random changes" -ForegroundColor White
        }
        Write-Host "   [3] Cleanup all test objects" -ForegroundColor White
        Write-Host "   [Q] Quit" -ForegroundColor White
        Write-Host ""

        $choice = Read-Host "   Select"
    }

    switch ($choice.ToUpper()) {
        '1' {
            Invoke-Create -State $State -Caps $Caps -Prefix $TestPrefix
            Save-State $State
        }
        '2' {
            if ($State.users.Count -eq 0) {
                Write-Host "`n  No test data exists. Create objects first." -ForegroundColor Yellow
            } else {
                Invoke-Changes -State $State -Caps $Caps
                Save-State $State
            }
        }
        '3' {
            if ($State.users.Count -eq 0 -and $State.azureResources.Count -eq 0) {
                Write-Host "`n  No test data to clean up." -ForegroundColor Yellow
            } else {
                Invoke-Cleanup -State $State -Caps $Caps
            }
        }
        'Q' {
            Write-Host "`n  Bye!" -ForegroundColor Gray
        }
        default {
            Write-Host "`n  Invalid choice." -ForegroundColor Yellow
        }
    }

    Write-Host ""
}
catch {
    Write-Error "Error: $_"
    exit 1
}

#endregion
