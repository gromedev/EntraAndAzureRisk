# Future Roadmap: BloodHound-Style Attack Path Discovery

> **Purpose:** Implementation roadmap for achieving BloodHound/AzureHound feature parity, enabling graph-based attack path visualization and discovery.

---

## Executive Summary

This project already collects the foundational data for attack path analysis:
- **8 entity types** (users, groups, service principals, apps, devices, etc.)
- **15+ relationship types** (memberships, roles, PIM, RBAC, ownership, OAuth2, app roles)
- **Delta detection** with permanent change history

**✅ Recently Completed (Part 1 - Property & Collection Gaps):**
- OAuth2 permission grants collection
- App role assignments collection
- Federated identity credentials on apps
- requiredResourceAccess (API permissions) on apps
- Group owners relationship
- Device owners relationship
- User password/session timestamps (lastPasswordChangeDateTime, signInSessionsValidFromDateTime, refreshTokensValidFromDateTime)
- Named locations for conditional access
- Verified publisher info on apps
- Extension attributes on users

**What's remaining:**
1. **Abusable permission edges** - Derive attack paths from collected API permissions
2. **Azure resource hierarchy** - Subscriptions, resource groups, key vaults, VMs
3. **Graph visualization layer** - Path discovery and rendering
4. **Risk detection** - Risky users (requires P2 license)

---

## Part 1: Property & Collection Gaps

### Quick Reference: What's Missing

| Entity | Critical Gaps | Priority |
|--------|--------------|----------|
| **Users** | `lastPasswordChangeDateTime`, risk detection, session tokens | 🔴 High |
| **Groups** | Group owners, lifecycle policies, sensitivity labels | 🔴 High |
| **Service Principals** | OAuth2 consents, app role assignments, federated credentials | 🔴 Critical |
| **Applications** | `requiredResourceAccess` (API permissions), verified publisher | 🔴 Critical |
| **Devices** | Device owners, BitLocker keys, extension attributes | 🟡 Medium |
| **Policies** | Named locations, auth methods policies, cross-tenant access | 🟡 Medium |

---

## 1.1 User Collection Gaps

**File:** `FunctionApp/CollectUsersWithAuthMethods/run.ps1`

### Currently Collected
- Core: `userPrincipalName`, `displayName`, `accountEnabled`, `userType`, `createdDateTime`
- Sign-in: `signInActivity` (basic), `usageLocation`
- Hybrid: `onPremisesSyncEnabled`, `onPremisesSamAccountName`, `onPremisesSecurityIdentifier`
- Auth methods: `perUserMfaState`, `hasAuthenticator`, `hasPhone`, `hasFido2`, etc.
- External: `externalUserState`, `externalUserStateChangeDateTime`

### Missing - Critical

| Property | Graph API | Use Case | License |
|----------|-----------|----------|---------|
| `lastPasswordChangeDateTime` | `/users?$select=lastPasswordChangeDateTime` | Password age tracking, compliance | None |
| `passwordProfile` | `/users?$select=passwordProfile` | Password expiration flags | None |
| `riskLevel` | `/identityProtection/riskyUsers` | Compromised account detection | **P2** |
| `riskState` | `/identityProtection/riskyUsers` | Risk status (atRisk, confirmedCompromised) | **P2** |
| `riskDetail` | `/identityProtection/riskyUsers` | Specific risk reasons | **P2** |

### Missing - High Priority

| Property | Graph API | Use Case |
|----------|-----------|----------|
| `signInSessionsValidFromDateTime` | `/users?$select=signInSessionsValidFromDateTime` | Session revocation tracking |
| `refreshTokensValidFromDateTime` | `/users?$select=refreshTokensValidFromDateTime` | Token invalidation tracking |
| `lastSuccessfulSignInDateTime` | `signInActivity` expansion | Identify truly inactive accounts |
| `lastNonInteractiveSignInDateTime` | `signInActivity` expansion | Service account activity |

### Missing - Medium Priority

| Property | Graph API | Use Case |
|----------|-----------|----------|
| `extensionAttribute1-15` | `/users?$select=onPremisesExtensionAttributes` | Custom security metadata |
| `isManagementRestricted` | `/users?$select=isManagementRestricted` | Restricted AU membership |
| `securityIdentifier` | `/users?$select=securityIdentifier` | Windows SID integration |

### Implementation

```powershell
# Update $selectFields in CollectUsersWithAuthMethods/run.ps1
$selectFields = "id,userPrincipalName,displayName,accountEnabled,userType,createdDateTime," +
    "signInActivity,passwordPolicies,usageLocation,externalUserState," +
    "onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesSecurityIdentifier," +
    # NEW FIELDS:
    "lastPasswordChangeDateTime," +                    # Password age
    "signInSessionsValidFromDateTime," +               # Session tracking
    "refreshTokensValidFromDateTime," +                # Token tracking
    "onPremisesExtensionAttributes," +                 # Custom attributes
    "isManagementRestricted"                           # Restricted AUs
```

### New Collector: Risk Detection (Requires P2)

```powershell
# New function: CollectRiskyUsers/run.ps1
$riskyUsers = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers"

# Schema
@{
    objectId = $user.id
    riskLevel = $user.riskLevel           # none, low, medium, high
    riskState = $user.riskState           # atRisk, confirmedCompromised, remediated
    riskDetail = $user.riskDetail         # Specific reason
    riskLastUpdatedDateTime = $user.riskLastUpdatedDateTime
}
```

---

## 1.2 Group Collection Gaps

**File:** `FunctionApp/CollectEntraGroups/run.ps1`

### Currently Collected
- Core: `displayName`, `description`, `mail`, `createdDateTime`
- Type: `groupTypes`, `securityEnabled`, `mailEnabled`, `isAssignableToRole`
- Dynamic: `membershipRule`, `visibility`, `classification`
- Counts: `memberCountDirect`, `userMemberCount`, `groupMemberCount`, etc.
- Hybrid: `onPremisesSyncEnabled`, `onPremisesSecurityIdentifier`

### Missing - Critical

| Property/Relationship | Status | Impact |
|----------------------|--------|--------|
| **Group Owners** | ❌ NOT COLLECTED | Cannot identify who controls groups |
| **Group Settings** | ❌ NOT COLLECTED | Missing lifecycle, expiration policies |
| **Sensitivity Labels** | ❌ NOT COLLECTED | No data classification visibility |

### Missing - High Priority

| Property | Graph API | Use Case |
|----------|-----------|----------|
| `expirationDateTime` | Group lifecycle | When group expires |
| `renewedDateTime` | Group lifecycle | Last renewal date |
| `resourceProvisioningOptions` | Group properties | Teams-backed groups |
| `theme` | Group properties | Teams theme |
| Access review assignments | `/identityGovernance/accessReviews` | Governance compliance |

### Implementation: Group Owners

Add to `CollectRelationships/run.ps1` as new phase:

```powershell
#region Phase 8: Group Owners
Write-Verbose "=== Phase 8: Collecting group owners ==="

$groupOwnerCount = 0
foreach ($group in $allGroups) {
    $ownersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners"
    $owners = Invoke-GraphWithRetry -Uri $ownersUri -AccessToken $graphToken

    foreach ($owner in $owners.value) {
        $relationship = @{
            id = "$($owner.id)_$($group.id)_groupOwner"
            relationType = "groupOwner"
            sourceId = $owner.id
            sourceType = $owner.'@odata.type'.Replace('#microsoft.graph.', '')
            sourceDisplayName = $owner.displayName
            sourceUserPrincipalName = $owner.userPrincipalName
            targetId = $group.id
            targetType = "group"
            targetDisplayName = $group.displayName
            targetSecurityEnabled = $group.securityEnabled
            targetIsAssignableToRole = $group.isAssignableToRole
            collectionTimestamp = $timestampFormatted
        }
        [void]$relationshipsJsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
        $groupOwnerCount++
    }
}
#endregion
```

---

## 1.3 Service Principal & Application Gaps

**Files:**
- `FunctionApp/CollectEntraServicePrincipals/run.ps1`
- `FunctionApp/CollectAppRegistrations/run.ps1`

### Currently Collected
- Core: `appId`, `displayName`, `servicePrincipalType`, `accountEnabled`
- Credentials: `passwordCredentials`, `keyCredentials` (with expiry status)
- Ownership: `appOwner`, `spOwner` relationships

### Missing - Critical (Attack Path Essential)

| Data | Graph API | Impact |
|------|-----------|--------|
| **API Permissions Requested** | `/applications/{id}?$select=requiredResourceAccess` | What permissions app CAN request |
| **OAuth2 Permission Grants** | `/oauth2PermissionGrants` | What permissions are ACTUALLY GRANTED |
| **App Role Assignments** | `/servicePrincipals/{id}/appRoleAssignments` | Who has access to this app |
| **Federated Identity Credentials** | `/applications/{id}/federatedIdentityCredentials` | External system auth (GitHub, K8s) |

### Missing - High Priority

| Data | Graph API | Impact |
|------|-----------|--------|
| Token configuration | `/applications/{id}?$select=optionalClaims` | Claims manipulation risks |
| Claims mapping policies | `/servicePrincipals/{id}/claimsMappingPolicies` | Token abuse vectors |
| Verified publisher | `/applications/{id}?$select=verifiedPublisher` | Trust verification |

### Implementation: OAuth2 Permission Grants

New relationship type for consents:

```powershell
# Add to CollectRelationships/run.ps1

#region Phase 9: OAuth2 Permission Grants (Consents)
Write-Verbose "=== Phase 9: Collecting OAuth2 permission grants ==="

$grantsUri = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$top=$batchSize"
while ($grantsUri) {
    $response = Invoke-GraphWithRetry -Uri $grantsUri -AccessToken $graphToken

    foreach ($grant in $response.value) {
        $relationship = @{
            id = $grant.id
            relationType = "oauth2PermissionGrant"
            sourceId = $grant.principalId ?? "AllPrincipals"  # null = admin consent for all
            sourceType = if ($grant.principalId) { "user" } else { "tenant" }
            targetId = $grant.resourceId                      # The resource SP being accessed
            targetType = "servicePrincipal"
            clientId = $grant.clientId                        # The app with the permission
            consentType = $grant.consentType                  # "AllPrincipals" or "Principal"
            scope = $grant.scope                              # "User.Read Mail.Read"
            collectionTimestamp = $timestampFormatted
        }
        [void]$relationshipsJsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
    }
    $grantsUri = $response.'@odata.nextLink'
}
#endregion
```

### Implementation: App Role Assignments

```powershell
#region Phase 10: App Role Assignments
Write-Verbose "=== Phase 10: Collecting app role assignments ==="

foreach ($sp in $allServicePrincipals) {
    $assignmentsUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo"
    $assignments = Invoke-GraphWithRetry -Uri $assignmentsUri -AccessToken $graphToken

    foreach ($assignment in $assignments.value) {
        $relationship = @{
            id = $assignment.id
            relationType = "appRoleAssignment"
            sourceId = $assignment.principalId
            sourceType = $assignment.principalType.ToLower()
            sourceDisplayName = $assignment.principalDisplayName
            targetId = $assignment.resourceId
            targetType = "servicePrincipal"
            targetDisplayName = $assignment.resourceDisplayName
            appRoleId = $assignment.appRoleId
            createdDateTime = $assignment.createdDateTime
            collectionTimestamp = $timestampFormatted
        }
        [void]$relationshipsJsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
    }
}
#endregion
```

### Implementation: Federated Identity Credentials

```powershell
# Add to CollectAppRegistrations/run.ps1

foreach ($app in $appBatch) {
    # Existing credential collection...

    # NEW: Federated Identity Credentials
    $fedCredsUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)/federatedIdentityCredentials"
    try {
        $fedCreds = Invoke-GraphWithRetry -Uri $fedCredsUri -AccessToken $graphToken
        $appObj.federatedIdentityCredentials = @($fedCreds.value | ForEach-Object {
            @{
                id = $_.id
                name = $_.name
                issuer = $_.issuer              # e.g., "https://token.actions.githubusercontent.com"
                subject = $_.subject            # e.g., "repo:org/repo:ref:refs/heads/main"
                audiences = $_.audiences
                description = $_.description
            }
        })
        $appObj.hasFederatedCredentials = ($fedCreds.value.Count -gt 0)
    }
    catch {
        $appObj.federatedIdentityCredentials = @()
        $appObj.hasFederatedCredentials = $false
    }
}
```

---

## 1.4 Device Collection Gaps

**File:** `FunctionApp/CollectDevices/run.ps1`

### Currently Collected
- Core: `displayName`, `deviceId`, `accountEnabled`, `createdDateTime`
- OS: `operatingSystem`, `operatingSystemVersion`
- Compliance: `isCompliant`, `isManaged`, `trustType`, `profileType`
- Hardware: `manufacturer`, `model`
- Activity: `approximateLastSignInDateTime`, `registrationDateTime`

### Missing - High Priority

| Property/Relationship | Graph API | Use Case |
|----------------------|-----------|----------|
| **Device Owners** | `/devices/{id}/registeredOwners` | Who owns/manages device |
| **Registered Users** | `/devices/{id}/registeredUsers` | Who uses device |
| `extensionAttributes` | `/devices?$select=extensionAttributes` | Custom metadata |
| `managementType` | `/devices?$select=managementType` | MDM vs EAS |

### Missing - Medium Priority (Intune)

| Property | API | Use Case |
|----------|-----|----------|
| BitLocker keys | Intune API | Key recovery capability |
| Compliance policies | Intune API | Policy assignment |
| Device configuration | Intune API | Security baselines |

### Implementation: Device Owners

```powershell
# Add to CollectRelationships/run.ps1

#region Phase 11: Device Owners
Write-Verbose "=== Phase 11: Collecting device owners ==="

$devicesUri = "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName"
$devices = Invoke-GraphWithRetry -Uri $devicesUri -AccessToken $graphToken

foreach ($device in $devices.value) {
    $ownersUri = "https://graph.microsoft.com/v1.0/devices/$($device.id)/registeredOwners"
    $owners = Invoke-GraphWithRetry -Uri $ownersUri -AccessToken $graphToken

    foreach ($owner in $owners.value) {
        $relationship = @{
            id = "$($owner.id)_$($device.id)_deviceOwner"
            relationType = "deviceOwner"
            sourceId = $owner.id
            sourceType = "user"
            sourceDisplayName = $owner.displayName
            sourceUserPrincipalName = $owner.userPrincipalName
            targetId = $device.id
            targetType = "device"
            targetDisplayName = $device.displayName
            collectionTimestamp = $timestampFormatted
        }
        [void]$relationshipsJsonL.AppendLine(($relationship | ConvertTo-Json -Compress))
    }
}
#endregion
```

---

## 1.5 Policy Collection Gaps

**File:** `FunctionApp/CollectPolicies/run.ps1`

### Currently Collected
- Conditional Access policies (full detail)
- Role management policies
- Role management policy assignments

### Missing - High Priority

| Policy Type | Graph API | Impact |
|-------------|-----------|--------|
| **Named Locations** | `/identity/conditionalAccess/namedLocations` | CA policy context |
| **Auth Methods Policy** | `/policies/authenticationMethodsPolicy` | MFA requirements |
| **Auth Strength Policies** | `/policies/authenticationStrengthPolicies` | Phishing-resistant auth |
| **Cross-Tenant Access** | `/policies/crossTenantAccessPolicy` | B2B security |
| **Permission Grant Policies** | `/policies/permissionGrantPolicies` | App consent rules |

### Missing - Medium Priority

| Policy Type | Graph API | Impact |
|-------------|-----------|--------|
| Token lifetime policies | `/policies/tokenLifetimePolicies` | Session duration |
| Home realm discovery | `/policies/homeRealmDiscoveryPolicies` | Federation settings |
| Claims mapping | `/policies/claimsMappingPolicies` | Token manipulation |

### Implementation: Named Locations

```powershell
# Add to CollectPolicies/run.ps1

#region 4. Collect Named Locations
Write-Verbose "=== Phase 4: Collecting named locations ==="

$namedLocationsUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations"
$response = Invoke-GraphWithRetry -Uri $namedLocationsUri -AccessToken $graphToken

foreach ($location in $response.value) {
    $locationType = $location.'@odata.type'.Replace('#microsoft.graph.', '')

    $locationObj = @{
        id = $location.id
        objectId = $location.id
        policyType = "namedLocation"
        locationType = $locationType    # ipNamedLocation or countryNamedLocation
        displayName = $location.displayName
        createdDateTime = $location.createdDateTime
        modifiedDateTime = $location.modifiedDateTime
        isTrusted = $location.isTrusted
        collectionTimestamp = $timestampFormatted
    }

    if ($locationType -eq 'ipNamedLocation') {
        $locationObj.ipRanges = $location.ipRanges
    }
    elseif ($locationType -eq 'countryNamedLocation') {
        $locationObj.countriesAndRegions = $location.countriesAndRegions
        $locationObj.includeUnknownCountriesAndRegions = $location.includeUnknownCountriesAndRegions
    }

    [void]$policiesJsonL.AppendLine(($locationObj | ConvertTo-Json -Compress -Depth 5))
}
#endregion
```

---

## 1.6 Summary: Property Gap Priority Matrix

| Priority | Entity | Gap | Effort | Status |
|----------|--------|-----|--------|--------|
| 🔴 **P0** | Apps/SPs | OAuth2 permission grants | Medium | ✅ **DONE** |
| 🔴 **P0** | Apps/SPs | App role assignments | Medium | ✅ **DONE** |
| 🔴 **P0** | Apps | Federated identity credentials | Low | ✅ **DONE** |
| 🔴 **P0** | Apps | `requiredResourceAccess` | Low | ✅ **DONE** |
| 🔴 **P1** | Groups | Group owners | Medium | ✅ **DONE** |
| 🔴 **P1** | Users | `lastPasswordChangeDateTime` | Low | ✅ **DONE** |
| 🔴 **P1** | Users | Risk detection (P2) | Medium | ⏳ Requires P2 license |
| 🟡 **P2** | Devices | Device owners | Medium | ✅ **DONE** |
| 🟡 **P2** | Policies | Named locations | Low | ✅ **DONE** |
| 🟡 **P2** | Users | Session/token timestamps | Low | ✅ **DONE** |
| 🟢 **P3** | Apps | Verified publisher | Low | ✅ **DONE** |
| 🟢 **P3** | Users | Extension attributes | Low | ✅ **DONE** |

---

## Part 2: BloodHound Feature Parity

## Current State vs BloodHound

### Entity Coverage

| Entity | BloodHound | Current | Status |
|--------|------------|---------|--------|
| Users | AZUser | ✅ | Complete |
| Groups | AZGroup | ✅ | Complete |
| Service Principals | AZServicePrincipal | ✅ | Complete |
| Applications | AZApp | ✅ | Complete |
| Devices | AZDevice | ✅ | Complete |
| Directory Roles | AZRole | ✅ | Complete |
| Tenant | AZTenant | ❌ | Phase 2 |
| Subscriptions | AZSubscription | ⚠️ | Phase 2 |
| Management Groups | AZManagementGroup | ❌ | Phase 2 |
| Resource Groups | AZResourceGroup | ⚠️ | Phase 2 |
| Key Vaults | AZKeyVault | ❌ | Phase 2 |
| Virtual Machines | AZVM | ❌ | Phase 2 |
| VM Scale Sets | AZVMScaleSet | ❌ | Phase 3 |
| Automation Accounts | AZAutomationAccount | ❌ | Phase 3 |
| Function Apps | AZFunctionApp | ❌ | Phase 3 |
| Logic Apps | AZLogicApp | ❌ | Phase 3 |
| Web Apps | AZWebApp | ❌ | Phase 3 |
| AKS Clusters | AZManagedCluster | ❌ | Phase 3 |
| Container Registries | AZContainerRegistry | ❌ | Phase 3 |

### Relationship Coverage

| Relationship | BloodHound | Current | Status |
|--------------|------------|---------|--------|
| Group Membership | AZMemberOf | ✅ `groupMember` | Complete |
| Transitive Membership | (computed) | ✅ `groupMemberTransitive` | Complete |
| Directory Roles | AZHasRole | ✅ `directoryRole` | Complete |
| PIM Eligible | AZRoleEligible | ✅ `pimEligible` | Complete |
| PIM Active | (active) | ✅ `pimActive` | Complete |
| Ownership | AZOwns | ✅ `appOwner`, `spOwner` | Complete |
| Azure RBAC | AZContributor, etc. | ✅ `azureRbac` | Complete |
| **API Permission Abuse** | AZMGxxx edges | ❌ | **Phase 1** |
| Hierarchy Containment | AZContains | ❌ | Phase 2 |
| Managed Identity Link | AZManagedIdentity | ❌ | Phase 2 |
| Add Secret Ability | AZAddSecret | ❌ | Phase 1 |
| Key Vault Access | AZGetSecrets, etc. | ❌ | Phase 2 |
| VM Execution | AZExecuteCommand | ❌ | Phase 2 |

---

## Phase 1: Quick Wins (Abuse Edge Mapping)

**Effort:** Low - Data already collected, need edge derivation logic
**Impact:** High - Enables core attack path discovery

### 1.1 Dangerous API Permission Mapping

We already collect `appRoleAssignment` relationships. Need to analyze which permissions grant attack capabilities.

#### Dangerous Microsoft Graph Permissions

| Permission | Abuse Capability | Edge Type |
|------------|------------------|-----------|
| `Application.ReadWrite.All` | Add secrets to any app | `canAddSecretToAnyApp` |
| `AppRoleAssignment.ReadWrite.All` | Grant any API permission | `canGrantAnyPermission` |
| `RoleManagement.ReadWrite.Directory` | Assign any directory role | `canAssignAnyRole` |
| `Directory.ReadWrite.All` | Modify any directory object | `canModifyDirectory` |
| `Group.ReadWrite.All` | Add self to any group | `canModifyAnyGroup` |
| `GroupMember.ReadWrite.All` | Add members to any group | `canAddAnyGroupMember` |
| `User.ReadWrite.All` | Modify any user | `canModifyAnyUser` |
| `ServicePrincipalEndpoint.ReadWrite.All` | Modify SP endpoints | `canModifySPEndpoints` |

#### Implementation

**New Relationship Types:**
```powershell
# Derived from appRoleAssignment where resourceDisplayName = "Microsoft Graph"
@{
    relationType = "graphApiAbuse"
    sourceId = "service-principal-id"
    sourceType = "servicePrincipal"
    targetId = "microsoft-graph-sp-id"  # or "all-apps" for tenant-wide
    abuseType = "canAddSecretToAnyApp"
    grantingPermission = "Application.ReadWrite.All"
    grantingPermissionId = "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
}
```

**New Function:** `DeriveAbuseEdges/run.ps1`
```powershell
# Runs after IndexRelationshipsInCosmosDB
# Reads appRoleAssignment relationships
# Outputs derived abuse edges to relationships container
```

**Dangerous Permission Reference Table:**
```powershell
$DangerousPermissions = @{
    # Microsoft Graph - Application Permissions
    "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9" = @{
        Name = "Application.ReadWrite.All"
        AbuseType = "canAddSecretToAnyApp"
        Severity = "Critical"
    }
    "06b708a9-e830-4db3-a914-8e69da51d44f" = @{
        Name = "AppRoleAssignment.ReadWrite.All"
        AbuseType = "canGrantAnyPermission"
        Severity = "Critical"
    }
    "9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8" = @{
        Name = "RoleManagement.ReadWrite.Directory"
        AbuseType = "canAssignAnyRole"
        Severity = "Critical"
    }
    # ... more mappings
}
```

### 1.2 Role-Based Abuse Edges

Certain directory roles grant implicit abuse capabilities:

| Role | Abuse Capability | Edge Type |
|------|------------------|-----------|
| Global Administrator | Everything | `isGlobalAdmin` |
| Privileged Role Administrator | Assign any role | `canAssignAnyRole` |
| Application Administrator | Add secrets to any app | `canAddSecretToAnyApp` |
| Cloud Application Administrator | Add secrets to any app | `canAddSecretToAnyApp` |
| Groups Administrator | Modify any group | `canModifyAnyGroup` |
| User Administrator | Reset passwords, modify users | `canModifyAnyUser` |
| Authentication Administrator | Reset MFA | `canResetMFA` |
| Privileged Authentication Admin | Reset any user's auth | `canResetAnyAuth` |

**Implementation:** Extend existing `directoryRole` relationships with `abuseCapabilities` array.

### 1.3 Ownership-Based Abuse

Owners of apps/SPs can add credentials:

```powershell
# Derive from existing appOwner/spOwner relationships
@{
    relationType = "ownershipAbuse"
    sourceId = "owner-user-id"
    targetId = "owned-app-id"
    abuseType = "canAddSecret"
    viaRelation = "appOwner"
}
```

### 1.4 Schema Changes

**IndexerConfigs.psd1 additions:**
```powershell
abuseEdges = @{
    EntityType = 'relationships'
    CompareFields = @(
        'sourceId'
        'targetId'
        'abuseType'
        'grantingPermission'
        'severity'
    )
    PartitionKey = 'sourceId'
}
```

---

## Phase 2: Azure Resource Collection

**Effort:** Medium - New API integrations required
**Impact:** High - Enables Azure attack path discovery

### 2.1 Azure Resource Hierarchy

Need to collect the containment hierarchy:
```
Tenant
  └── Management Groups
        └── Subscriptions
              └── Resource Groups
                    └── Resources (VMs, Key Vaults, etc.)
```

#### New Entity Types

**Tenant:**
```json
{
    "id": "tenant-id",
    "principalType": "tenant",
    "displayName": "Contoso",
    "tenantId": "...",
    "defaultDomain": "contoso.onmicrosoft.com",
    "verifiedDomains": [...]
}
```

**Management Group:**
```json
{
    "id": "mg-id",
    "principalType": "managementGroup",
    "displayName": "Root Management Group",
    "managementGroupId": "...",
    "parentId": "tenant-id"
}
```

**Subscription:**
```json
{
    "id": "subscription-id",
    "principalType": "subscription",
    "displayName": "Production",
    "subscriptionId": "...",
    "state": "Enabled",
    "parentId": "management-group-id"
}
```

**Resource Group:**
```json
{
    "id": "resource-group-id",
    "principalType": "resourceGroup",
    "displayName": "rg-production-001",
    "location": "eastus",
    "subscriptionId": "...",
    "parentId": "subscription-id"
}
```

#### New Relationship Type: `contains`

```json
{
    "relationType": "contains",
    "sourceId": "tenant-id",
    "sourceType": "tenant",
    "targetId": "management-group-id",
    "targetType": "managementGroup"
}
```

#### APIs Required

| Entity | API | Endpoint |
|--------|-----|----------|
| Tenant | Graph | `GET /organization` |
| Management Groups | ARM | `GET /providers/Microsoft.Management/managementGroups` |
| Subscriptions | ARM | `GET /subscriptions` |
| Resource Groups | ARM | `GET /subscriptions/{id}/resourcegroups` |

#### New Collector: `CollectAzureHierarchy/run.ps1`

```powershell
# 1. Get tenant info from Graph
$tenant = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization"

# 2. Get management groups from ARM
$mgmtGroups = Invoke-AzRestMethod -Path "/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"

# 3. Get subscriptions
$subscriptions = Get-AzSubscription

# 4. For each subscription, get resource groups
foreach ($sub in $subscriptions) {
    $rgs = Get-AzResourceGroup -SubscriptionId $sub.Id
}

# 5. Output to hierarchy.jsonl with contains relationships
```

### 2.2 Key Vault Collection

Critical for secret access attack paths.

#### Entity Schema

```json
{
    "id": "keyvault-resource-id",
    "principalType": "keyVault",
    "displayName": "kv-production-001",
    "vaultUri": "https://kv-production-001.vault.azure.net/",
    "location": "eastus",
    "subscriptionId": "...",
    "resourceGroupId": "...",
    "sku": "standard",
    "enableRbacAuthorization": true,
    "enableSoftDelete": true,
    "enablePurgeProtection": true,
    "secretCount": 15,
    "keyCount": 3,
    "certificateCount": 2
}
```

#### Key Vault Access Relationships

**RBAC-based access (modern):**
```json
{
    "relationType": "keyVaultAccess",
    "sourceId": "user-or-sp-id",
    "targetId": "keyvault-id",
    "accessType": "rbac",
    "roleDefinitionName": "Key Vault Secrets User",
    "capabilities": ["getSecrets", "listSecrets"]
}
```

**Access Policy-based (legacy):**
```json
{
    "relationType": "keyVaultAccess",
    "sourceId": "user-or-sp-id",
    "targetId": "keyvault-id",
    "accessType": "accessPolicy",
    "secretPermissions": ["get", "list"],
    "keyPermissions": ["get", "list", "unwrapKey"],
    "certificatePermissions": ["get", "list"]
}
```

#### Abuse Edge Derivation

| Access | Abuse Type |
|--------|------------|
| secrets/get | `canGetSecrets` |
| secrets/set | `canSetSecrets` |
| keys/get + keys/unwrapKey | `canDecryptWithKey` |
| certificates/get | `canGetCertificates` |
| Contributor on RG containing KV | `canModifyKeyVault` |

#### API

```powershell
# List all Key Vaults
GET /subscriptions/{sub}/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01

# Get access policies (for non-RBAC vaults)
GET /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{name}?api-version=2023-07-01
```

### 2.3 Virtual Machine Collection

For lateral movement and execution attack paths.

#### Entity Schema

```json
{
    "id": "vm-resource-id",
    "principalType": "virtualMachine",
    "displayName": "vm-web-prod-001",
    "vmId": "...",
    "location": "eastus",
    "subscriptionId": "...",
    "resourceGroupId": "...",
    "vmSize": "Standard_D4s_v3",
    "osType": "Windows",
    "osName": "Windows Server 2022",
    "powerState": "running",
    "provisioningState": "Succeeded",

    "identity": {
        "type": "SystemAssigned, UserAssigned",
        "systemAssignedPrincipalId": "sp-id",
        "userAssignedIdentities": [
            {"principalId": "...", "clientId": "..."}
        ]
    },

    "networkInterfaces": ["nic-id-1"],
    "publicIpAddresses": ["1.2.3.4"],
    "privateIpAddresses": ["10.0.0.4"]
}
```

#### VM Abuse Relationships

| RBAC Role | Abuse Type | Edge |
|-----------|------------|------|
| Virtual Machine Contributor | Can run commands | `canExecuteCommandOnVM` |
| Virtual Machine Administrator Login | Can RDP/SSH as admin | `canAdminLoginToVM` |
| Virtual Machine User Login | Can RDP/SSH as user | `canUserLoginToVM` |

#### Managed Identity Link

```json
{
    "relationType": "hasManagedIdentity",
    "sourceId": "vm-resource-id",
    "sourceType": "virtualMachine",
    "targetId": "managed-identity-sp-id",
    "targetType": "servicePrincipal",
    "identityType": "SystemAssigned"
}
```

This creates the attack path:
```
User → Contributor on RG → can execute on VM → VM has managed identity → SP has Graph permissions
```

#### APIs

```powershell
# List all VMs in subscription
GET /subscriptions/{sub}/providers/Microsoft.Compute/virtualMachines?api-version=2024-03-01

# Get VM with instance view (for power state)
GET /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{name}?$expand=instanceView&api-version=2024-03-01
```

### 2.4 Managed Identity Linking

Connect managed identities (already collected as SPs) to their resources.

**Current gap:** We collect managed identity SPs but don't know which resource owns them.

**Solution:** When collecting VMs, Function Apps, etc., capture identity info and create `hasManagedIdentity` relationships.

```json
{
    "relationType": "hasManagedIdentity",
    "sourceId": "resource-id",
    "sourceType": "virtualMachine|functionApp|logicApp|...",
    "targetId": "managed-identity-sp-id",
    "targetType": "servicePrincipal",
    "identityType": "SystemAssigned|UserAssigned"
}
```

---

## Phase 3: Full AzureHound Parity

**Effort:** High - Many new resource types
**Impact:** Medium - Completeness for edge cases

### 3.1 Compute Resources

| Resource | API | Priority |
|----------|-----|----------|
| VM Scale Sets | ARM Compute | Medium |
| AKS Clusters | ARM ContainerService | Medium |
| Container Instances | ARM ContainerInstance | Low |
| App Services / Web Apps | ARM Web | Medium |
| Function Apps | ARM Web | High (code execution) |

### 3.2 Automation Resources

| Resource | Attack Vector | Priority |
|----------|---------------|----------|
| Automation Accounts | Runbook execution | High |
| Logic Apps | Workflow execution with identity | High |
| Data Factory | Pipeline execution | Medium |

**Automation Account Abuse:**
- Contributor → can create/modify runbooks
- Runbooks execute as Automation Account's Run As account or managed identity
- Often have privileged access for automation tasks

### 3.3 Storage Resources

| Resource | Attack Vector | Priority |
|----------|---------------|----------|
| Storage Accounts | Blob/file access, SAS abuse | Medium |
| Container Registries | Image pull/push | Medium |
| Cosmos DB | Data access | Low |
| SQL Databases | Data access | Low |

### 3.4 Hybrid Identity

For environments with on-prem AD sync:

```json
{
    "relationType": "syncedToEntraUser",
    "sourceId": "onprem-user-sid",
    "sourceType": "adUser",
    "targetId": "entra-user-objectid",
    "targetType": "user",
    "syncSource": "Azure AD Connect"
}
```

**Note:** Requires AD collection (SharpHound equivalent) which is out of scope for this project.

---

## Phase 4: Graph Visualization

### Options Comparison

| Option | Pros | Cons | Effort |
|--------|------|------|--------|
| **Export to BloodHound** | Mature UI, path algorithms built-in | Requires Neo4j, data duplication | Low |
| **Neo4j + Custom UI** | Native graph queries, proven scale | Additional infrastructure | Medium |
| **Cosmos Gremlin API** | Same infrastructure, Azure-native | Less mature tooling | Medium |
| **Custom + Cytoscape.js** | Full control, no new infra | Must implement path algorithms | High |

### Recommended: Hybrid Approach

1. **Primary:** Keep Cosmos DB as source of truth
2. **Query Layer:** Add Neo4j for graph queries (or Cosmos Gremlin container)
3. **Visualization:** Web UI with Cytoscape.js or Sigma.js
4. **Export:** Optional BloodHound JSON export for users who prefer that UI

### Path Discovery Queries (Cypher Examples)

```cypher
// Find all paths from User X to Global Admin
MATCH path = (u:User {objectId: 'xxx'})-[*1..6]->(r:Role {name: 'Global Administrator'})
RETURN path

// Find shortest path to any privileged role
MATCH path = shortestPath(
    (u:User {objectId: 'xxx'})-[*1..10]->(r:Role {isPrivileged: true})
)
RETURN path

// Find all principals that can add secrets to apps
MATCH (p)-[:canAddSecretToAnyApp|:canAddSecret]->(target)
RETURN p, target
```

---

## Implementation Priority Matrix

| Phase | Item | Effort | Impact | Dependencies |
|-------|------|--------|--------|--------------|
| **1.1** | Dangerous permission mapping | Low | Critical | Existing data |
| **1.2** | Role-based abuse edges | Low | High | Existing data |
| **1.3** | Ownership abuse edges | Low | High | Existing data |
| **2.1** | Azure hierarchy | Medium | High | ARM API access |
| **2.2** | Key Vault collection | Medium | Critical | ARM API access |
| **2.3** | VM collection | Medium | High | ARM API access |
| **2.4** | Managed Identity linking | Low | High | Phase 2.3 |
| **3.x** | Additional resources | High | Medium | ARM API access |
| **4.x** | Graph visualization | High | High | Phases 1-2 |

---

## Required Permissions

### Current (Graph API)
Already have what's needed for Phase 1.

### New for Phase 2+ (Azure ARM)

| Permission | Scope | Purpose |
|------------|-------|---------|
| `Reader` | Management Group root | List hierarchy |
| `Reader` | Subscriptions | List resources |
| `Key Vault Reader` | Key Vaults | Read vault metadata |
| `Microsoft.KeyVault/vaults/accessPolicies/read` | Key Vaults | Read access policies |

**Managed Identity role assignments:**
```bash
# At management group root (for hierarchy traversal)
az role assignment create \
    --assignee <function-app-identity> \
    --role "Reader" \
    --scope "/providers/Microsoft.Management/managementGroups/<root-mg>"
```

---

## New Files to Create

### Phase 1
- `FunctionApp/DeriveAbuseEdges/run.ps1` - Abuse edge derivation logic
- `FunctionApp/DeriveAbuseEdges/function.json` - Timer/orchestrator trigger
- `FunctionApp/Modules/EntraDataCollection/DangerousPermissions.psd1` - Permission reference

### Phase 2
- `FunctionApp/CollectAzureHierarchy/run.ps1` - Tenant, MGs, Subs, RGs
- `FunctionApp/CollectKeyVaults/run.ps1` - Key Vault collection
- `FunctionApp/CollectVirtualMachines/run.ps1` - VM collection
- `FunctionApp/IndexAzureResourcesInCosmosDB/run.ps1` - Azure resource indexer

### Phase 3+
- Additional collectors as needed

---

## Success Metrics

| Metric | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|
| Attack path queries possible | Basic (role-based) | Azure resources | Complete |
| BloodHound edge parity | ~30% | ~70% | ~95% |
| New relationship types | 5-8 | 15-20 | 40+ |
| Visualization | None | Dashboard queries | Full graph UI |

---

## References

- [BloodHound Documentation](https://bloodhound.specterops.io/)
- [AzureHound GitHub](https://github.com/SpecterOps/AzureHound)
- [BloodHound 4.2 Azure Refactor](https://specterops.io/blog/2022/08/03/introducing-bloodhound-4-2-the-azure-refactor/)
- [Microsoft Graph API Permissions Reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Azure RBAC Built-in Roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles)

---

## Appendix A: Property-Level Gap Analysis vs BloodHound/AzureHound

> **Last Updated:** 2026-01-07
> This section provides a detailed property-by-property comparison between this project and BloodHound/AzureHound.

### A.1 User Properties (AZUser)

| Property | BloodHound | This Project | Status |
|----------|------------|--------------|--------|
| `id` / `objectId` | ✅ | ✅ | ✅ Match |
| `displayName` | ✅ | ✅ | ✅ Match |
| `userPrincipalName` | ✅ | ✅ | ✅ Match |
| `enabled` / `accountEnabled` | ✅ | ✅ | ✅ Match |
| `userType` (Member/Guest) | ✅ | ✅ | ✅ Match |
| `tenantId` | ✅ | ❌ | ⚠️ Gap (implicit) |
| `createdDateTime` | ❌ | ✅ | ✅ We have more |
| `lastSignInDateTime` | ❌ | ✅ | ✅ We have more |
| `lastPasswordChangeDateTime` | ❌ | ✅ | ✅ We have more |
| `signInSessionsValidFromDateTime` | ❌ | ✅ | ✅ We have more |
| `refreshTokensValidFromDateTime` | ❌ | ✅ | ✅ We have more |
| `passwordPolicies` | ❌ | ✅ | ✅ We have more |
| `usageLocation` | ❌ | ✅ | ✅ We have more |
| `onPremisesSyncEnabled` | ✅ | ✅ | ✅ Match |
| `onPremisesSamAccountName` | ✅ | ✅ | ✅ Match |
| `onPremisesSecurityIdentifier` | ✅ | ✅ | ✅ Match |
| `onPremisesDomainName` | ✅ | ❌ | ⚠️ Gap |
| `onPremisesUserPrincipalName` | ❌ | ✅ | ✅ We have more |
| `onPremisesExtensionAttributes` | ❌ | ✅ | ✅ We have more |
| `externalUserState` | ❌ | ✅ | ✅ We have more |
| `externalUserStateChangeDateTime` | ❌ | ✅ | ✅ We have more |
| **Authentication Methods** | | | |
| `perUserMfaState` | ❌ | ✅ | ✅ We have more |
| `hasAuthenticator` | ❌ | ✅ | ✅ We have more |
| `hasPhone` | ❌ | ✅ | ✅ We have more |
| `hasFido2` | ❌ | ✅ | ✅ We have more |
| `hasWindowsHello` | ❌ | ✅ | ✅ We have more |
| `hasSoftwareOath` | ❌ | ✅ | ✅ We have more |
| `authMethodCount` | ❌ | ✅ | ✅ We have more |
| **Risk (Requires P2)** | | | |
| `riskLevel` | ❌ | ❌ | ⏳ Future |
| `riskState` | ❌ | ❌ | ⏳ Future |

**Summary:** We collect **significantly more** user properties than BloodHound, especially around authentication methods, sign-in activity, and security timestamps. BloodHound focuses on identity for attack path traversal; we focus on security posture assessment.

**Minor Gap:** `onPremisesDomainName` - can add to $selectFields if needed.

---

### A.2 Group Properties (AZGroup)

| Property | BloodHound | This Project | Status |
|----------|------------|--------------|--------|
| `id` / `objectId` | ✅ | ✅ | ✅ Match |
| `displayName` | ✅ | ✅ | ✅ Match |
| `description` | ✅ | ✅ | ✅ Match |
| `securityEnabled` | ✅ | ✅ | ✅ Match |
| `mailEnabled` | ✅ | ✅ | ✅ Match |
| `isAssignableToRole` | ✅ | ✅ | ✅ Match |
| `membershipRule` | ✅ | ✅ | ✅ Match |
| `membershipRuleProcessingState` | ✅ | ✅ | ✅ Match |
| `groupTypes` | ✅ | ✅ | ✅ Match |
| `visibility` | ❌ | ✅ | ✅ We have more |
| `classification` | ❌ | ✅ | ✅ We have more |
| `createdDateTime` | ❌ | ✅ | ✅ We have more |
| `mail` | ❌ | ✅ | ✅ We have more |
| `onPremisesSyncEnabled` | ✅ | ✅ | ✅ Match |
| `onPremisesSecurityIdentifier` | ✅ | ✅ | ✅ Match |
| `onPremisesDomainName` | ✅ | ❌ | ⚠️ Gap |
| `onPremisesSamAccountName` | ❌ | ✅ | ✅ We have more |
| **Member Counts** | | | |
| `memberCount` | ❌ | ✅ | ✅ We have more |
| `userMemberCount` | ❌ | ✅ | ✅ We have more |
| `groupMemberCount` | ❌ | ✅ | ✅ We have more |
| `servicePrincipalMemberCount` | ❌ | ✅ | ✅ We have more |

**Summary:** Full parity with BloodHound plus additional analytics fields.

**Minor Gap:** `onPremisesDomainName` - can add if needed.

---

### A.3 Service Principal Properties (AZServicePrincipal)

| Property | BloodHound | This Project | Status |
|----------|------------|--------------|--------|
| `id` / `objectId` | ✅ | ✅ | ✅ Match |
| `displayName` | ✅ | ✅ | ✅ Match |
| `appId` | ✅ | ✅ | ✅ Match |
| `accountEnabled` | ✅ | ✅ | ✅ Match |
| `servicePrincipalType` | ✅ | ✅ | ✅ Match |
| `appOwnerOrganizationId` | ✅ | ✅ | ✅ Match |
| `createdDateTime` | ❌ | ✅ | ✅ We have more |
| **Credentials** | | | |
| `passwordCredentials` | ✅ | ✅ | ✅ Match |
| `keyCredentials` | ✅ | ✅ | ✅ Match |
| `secretCount` | ❌ | ✅ | ✅ We have more |
| `certificateCount` | ❌ | ✅ | ✅ We have more |
| **Credential Expiry Analysis** | | | |
| Expired/expiring counts | ❌ | ✅ | ✅ We have more |
| **Tags** | | | |
| `tags` (WindowsAzureActiveDirectoryIntegratedApp, etc.) | ✅ | ✅ | ✅ Match |
| `appDisplayName` | ❌ | ✅ | ✅ We have more |

**Summary:** Full parity plus credential expiry analytics.

---

### A.4 Application Properties (AZApp)

| Property | BloodHound | This Project | Status |
|----------|------------|--------------|--------|
| `id` / `objectId` | ✅ | ✅ | ✅ Match |
| `displayName` | ✅ | ✅ | ✅ Match |
| `appId` | ✅ | ✅ | ✅ Match |
| `publisherDomain` | ✅ | ✅ | ✅ Match |
| `signInAudience` | ✅ | ✅ | ✅ Match |
| `createdDateTime` | ❌ | ✅ | ✅ We have more |
| **Credentials** | | | |
| `passwordCredentials` | ✅ | ✅ | ✅ Match |
| `keyCredentials` | ✅ | ✅ | ✅ Match |
| Expiry status per credential | ❌ | ✅ | ✅ We have more |
| **API Permissions** | | | |
| `requiredResourceAccess` | ❌ | ✅ | ✅ We have more |
| `apiPermissionCount` | ❌ | ✅ | ✅ We have more |
| **Federated Identity** | | | |
| `federatedIdentityCredentials` | ❌ | ✅ | ✅ We have more |
| `hasFederatedCredentials` | ❌ | ✅ | ✅ We have more |
| **Publisher Verification** | | | |
| `verifiedPublisher` | ❌ | ✅ | ✅ We have more |
| `isPublisherVerified` | ❌ | ✅ | ✅ We have more |

**Summary:** We collect significantly more than BloodHound, especially federated identity credentials (workload identity federation) and API permissions.

---

### A.5 Device Properties (AZDevice)

| Property | BloodHound | This Project | Status |
|----------|------------|--------------|--------|
| `id` / `objectId` | ✅ | ✅ | ✅ Match |
| `displayName` | ✅ | ✅ | ✅ Match |
| `deviceId` | ✅ | ✅ | ✅ Match |
| `accountEnabled` | ✅ | ✅ | ✅ Match |
| `operatingSystem` | ✅ | ✅ | ✅ Match |
| `operatingSystemVersion` | ✅ | ✅ | ✅ Match |
| `trustType` | ✅ | ✅ | ✅ Match |
| `isManaged` | ✅ | ✅ | ✅ Match |
| `isCompliant` | ✅ | ✅ | ✅ Match |
| `profileType` | ❌ | ✅ | ✅ We have more |
| `createdDateTime` | ❌ | ✅ | ✅ We have more |
| `registrationDateTime` | ❌ | ✅ | ✅ We have more |
| `approximateLastSignInDateTime` | ❌ | ✅ | ✅ We have more |
| `manufacturer` | ❌ | ✅ | ✅ We have more |
| `model` | ❌ | ✅ | ✅ We have more |
| `mdmAppId` | ❌ | ✅ | ✅ We have more |

**Summary:** Full parity plus hardware and activity details.

---

### A.6 Relationship/Edge Comparison

| Relationship Type | BloodHound | This Project | Status |
|-------------------|------------|--------------|--------|
| **Membership** | | | |
| Group Membership | AZMemberOf | ✅ `groupMember` | ✅ Match |
| Transitive Membership | (computed) | ✅ `groupMemberTransitive` | ✅ We have more |
| Nested Groups | AZMemberOf | ✅ `nestedGroup` | ✅ We have more |
| **Roles** | | | |
| Directory Roles | AZHasRole | ✅ `directoryRole` | ✅ Match |
| **PIM** | | | |
| PIM Role Eligible | AZPIMRoleEligible | ✅ `pimEligible` | ✅ Match |
| PIM Role Active | AZPIMRoleActive | ✅ `pimActive` | ✅ Match |
| PIM Group Eligible | AZPIMGroupEligible | ✅ `pimGroupEligible` | ✅ Match |
| PIM Group Active | AZPIMGroupActive | ✅ `pimGroupActive` | ✅ Match |
| **Ownership** | | | |
| App Ownership | AZOwns | ✅ `appOwner` | ✅ Match |
| SP Ownership | AZOwns | ✅ `spOwner` | ✅ Match |
| Group Ownership | AZOwns | ✅ `groupOwner` | ✅ Match |
| Device Ownership | AZOwns | ✅ `deviceOwner` | ✅ Match |
| **Azure RBAC** | | | |
| Azure Role Assignments | AZContributor, etc. | ✅ `azureRbac` | ✅ Match |
| **OAuth/App Roles** | | | |
| OAuth2 Permission Grants | AZMGGrantAppRoles | ✅ `oauth2PermissionGrant` | ✅ Match |
| App Role Assignments | AZAppRoleAssignment | ✅ `appRoleAssignment` | ✅ Match |
| **Licensing** | | | |
| License Assignments | ❌ | ✅ `licenseAssignment` | ✅ We have more |
| **Azure Resources (Phase 2)** | | | |
| Contains (hierarchy) | AZContains | ❌ | ⏳ Phase 2 |
| Key Vault Access | AZGetSecrets, etc. | ❌ | ⏳ Phase 2 |
| VM Execution | AZVMContributor | ❌ | ⏳ Phase 2 |
| Managed Identity | AZManagedIdentity | ❌ | ⏳ Phase 2 |

**Summary:** We have **full parity** on Entra ID relationships and collect additional relationship types (licenses, transitive memberships) that BloodHound doesn't. Azure resource relationships are planned for Phase 2.

---

### A.7 Overall Parity Summary

| Category | BloodHound Coverage | Our Coverage | Gap Status |
|----------|---------------------|--------------|------------|
| **Entra ID Entities** | 6 types | 8 types | ✅ **Exceeds** |
| **User Properties** | ~12 fields | ~30 fields | ✅ **Exceeds** |
| **Group Properties** | ~10 fields | ~15 fields | ✅ **Exceeds** |
| **SP Properties** | ~10 fields | ~15 fields | ✅ **Exceeds** |
| **App Properties** | ~8 fields | ~18 fields | ✅ **Exceeds** |
| **Device Properties** | ~10 fields | ~15 fields | ✅ **Exceeds** |
| **Entra ID Relationships** | ~10 types | ~15 types | ✅ **Exceeds** |
| **Azure Resources** | ~12 types | 0 types | ⏳ Phase 2 |
| **Azure Relationships** | ~10 types | 0 types | ⏳ Phase 2 |
| **Attack Path Derivation** | Built-in | ❌ | ⏳ Phase 1 |
| **Graph Visualization** | Neo4j/BloodHound UI | ❌ | ⏳ Phase 4 |

### Remaining Gaps to Address

**Minor Property Gaps (Easy Fix):**
1. `onPremisesDomainName` for users and groups - add to $selectFields
2. `tenantId` - add tenant context to all entities

**Phase 1 Gaps (Abuse Edge Derivation):**
- Derive attack path edges from collected appRoleAssignment data
- Map dangerous API permissions to abuse capabilities

**Phase 2 Gaps (Azure Resources):**
- Azure hierarchy (Management Groups, Subscriptions, Resource Groups)
- Key Vaults with access policies
- Virtual Machines with managed identities
- Function Apps, Logic Apps, Automation Accounts

---

**End of Roadmap**
