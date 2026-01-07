# Future Roadmap: BloodHound-Style Attack Path Discovery

> **Purpose:** Implementation roadmap for achieving BloodHound/AzureHound feature parity, enabling graph-based attack path visualization and discovery.

---

## Executive Summary

This project already collects the foundational data for attack path analysis:
- **8 Entra ID entity types** (users, groups, service principals, apps, devices, etc.)
- **6 Azure resource types** (tenant, management groups, subscriptions, resource groups, key vaults, VMs)
- **18+ relationship types** (memberships, roles, PIM, RBAC, ownership, OAuth2, app roles, Azure hierarchy, managed identities)
- **Delta detection** with permanent change history

**✅ Completed (Part 1 - Property & Collection Gaps):**
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

**✅ Completed (Part 2 - Azure Resource Collection):**
- Azure hierarchy collection (tenant → management groups → subscriptions → resource groups)
- Key Vault collection with access policies and abuse flags
- Virtual Machine collection with managed identity linking
- Azure resource indexing to Cosmos DB
- Azure relationship indexing (contains, keyVaultAccess, hasManagedIdentity)

**What's remaining:**
1. **Abusable permission edges** - Derive attack paths from collected API permissions (Phase 1)
2. **Graph visualization layer** - Path discovery and rendering (Phase 4)
3. **Risk detection** - Risky users (requires P2 license)
4. **Additional Azure resources** - Automation accounts, Function Apps, Logic Apps, AKS (Phase 3)

---

## Part 1: Property & Collection Gaps

### Quick Reference: Implementation Status

| Entity | Status | Remaining Gaps |
|--------|--------|----------------|
| **Users** | ✅ Complete | Risk detection (requires P2 license) |
| **Groups** | ✅ Complete | Lifecycle policies, sensitivity labels (low priority) |
| **Service Principals** | ✅ Complete | None |
| **Applications** | ✅ Complete | None |
| **Devices** | ✅ Complete | BitLocker keys (Intune API, low priority) |
| **Policies** | ✅ Complete | Auth methods policies, cross-tenant access (medium priority) |

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
| Tenant | AZTenant | ✅ | **Complete** |
| Subscriptions | AZSubscription | ✅ | **Complete** |
| Management Groups | AZManagementGroup | ✅ | **Complete** |
| Resource Groups | AZResourceGroup | ✅ | **Complete** |
| Key Vaults | AZKeyVault | ✅ | **Complete** |
| Virtual Machines | AZVM | ✅ | **Complete** |
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
| Ownership | AZOwns | ✅ `appOwner`, `spOwner`, `groupOwner`, `deviceOwner` | Complete |
| Azure RBAC | AZContributor, etc. | ✅ `azureRbac` | Complete |
| OAuth2 Grants | AZMGGrantAppRoles | ✅ `oauth2PermissionGrant` | **Complete** |
| App Role Assignments | AZAppRoleAssignment | ✅ `appRoleAssignment` | **Complete** |
| Hierarchy Containment | AZContains | ✅ `contains` | **Complete** |
| Managed Identity Link | AZManagedIdentity | ✅ `hasManagedIdentity` | **Complete** |
| Key Vault Access | AZGetSecrets, etc. | ✅ `keyVaultAccess` | **Complete** |
| **API Permission Abuse** | AZMGxxx edges | ❌ | **Phase 1** |
| Add Secret Ability | AZAddSecret | ❌ | Phase 1 |
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

## Phase 2: Azure Resource Collection ✅ COMPLETE

**Effort:** Medium - New API integrations required
**Impact:** High - Enables Azure attack path discovery
**Status:** ✅ **IMPLEMENTED** - All Phase 2 collectors and indexers are operational

### 2.1 Azure Resource Hierarchy ✅ IMPLEMENTED

**File:** `FunctionApp/CollectAzureHierarchy/run.ps1`

Collects the full containment hierarchy:
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

### 2.2 Key Vault Collection ✅ IMPLEMENTED

**File:** `FunctionApp/CollectKeyVaults/run.ps1`

Critical for secret access attack paths. Collects vault metadata, security configuration, access policies, and derives abuse flags (canGetSecrets, canSetSecrets, canDecryptWithKey, etc.).

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

### 2.3 Virtual Machine Collection ✅ IMPLEMENTED

**File:** `FunctionApp/CollectVirtualMachines/run.ps1`

For lateral movement and execution attack paths. Collects VM metadata, OS info, power state, and managed identity information. Creates `hasManagedIdentity` relationships linking VMs to their service principals.

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

### 2.4 Managed Identity Linking ✅ IMPLEMENTED

Connect managed identities (already collected as SPs) to their resources.

**Implementation:** When collecting VMs, the collector captures identity info and creates `hasManagedIdentity` relationships for both system-assigned and user-assigned identities.

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

| Phase | Item | Effort | Impact | Dependencies | Status |
|-------|------|--------|--------|--------------|--------|
| **1.1** | Dangerous permission mapping | Low | Critical | Existing data | ❌ Not started |
| **1.2** | Role-based abuse edges | Low | High | Existing data | ❌ Not started |
| **1.3** | Ownership abuse edges | Low | High | Existing data | ❌ Not started |
| **2.1** | Azure hierarchy | Medium | High | ARM API access | ✅ **Complete** |
| **2.2** | Key Vault collection | Medium | Critical | ARM API access | ✅ **Complete** |
| **2.3** | VM collection | Medium | High | ARM API access | ✅ **Complete** |
| **2.4** | Managed Identity linking | Low | High | Phase 2.3 | ✅ **Complete** |
| **3.x** | Additional resources | High | Medium | ARM API access | ❌ Not started |
| **4.x** | Graph visualization | High | High | Phases 1-2 | ❌ Not started |

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

### Phase 1 - Still Needed
- `FunctionApp/DeriveAbuseEdges/run.ps1` - Abuse edge derivation logic
- `FunctionApp/DeriveAbuseEdges/function.json` - Timer/orchestrator trigger
- `FunctionApp/Modules/EntraDataCollection/DangerousPermissions.psd1` - Permission reference

### Phase 2 - ✅ Created
- ✅ `FunctionApp/CollectAzureHierarchy/run.ps1` - Tenant, MGs, Subs, RGs
- ✅ `FunctionApp/CollectAzureHierarchy/function.json`
- ✅ `FunctionApp/CollectKeyVaults/run.ps1` - Key Vault collection with access policies
- ✅ `FunctionApp/CollectKeyVaults/function.json`
- ✅ `FunctionApp/CollectVirtualMachines/run.ps1` - VM collection with managed identities
- ✅ `FunctionApp/CollectVirtualMachines/function.json`
- ✅ `FunctionApp/IndexAzureResourcesInCosmosDB/run.ps1` - Azure resource indexer
- ✅ `FunctionApp/IndexAzureResourcesInCosmosDB/function.json`
- ✅ `FunctionApp/IndexAzureRelationshipsInCosmosDB/run.ps1` - Azure relationship indexer
- ✅ `FunctionApp/IndexAzureRelationshipsInCosmosDB/function.json`

### Phase 3+
- Additional collectors as needed (Automation Accounts, Function Apps, Logic Apps, etc.)

---

## Success Metrics

| Metric | Phase 1 | Phase 2 | Phase 3 | Current Status |
|--------|---------|---------|---------|----------------|
| Attack path queries possible | Basic (role-based) | Azure resources | Complete | ✅ **Phase 2 Complete** |
| BloodHound edge parity | ~30% | ~70% | ~95% | **~60%** (need abuse edges) |
| New relationship types | 5-8 | 15-20 | 40+ | **18 types** implemented |
| Visualization | None | Dashboard queries | Full graph UI | Basic dashboard |

---

## References

- [BloodHound Documentation](https://bloodhound.specterops.io/)
- [AzureHound GitHub](https://github.com/SpecterOps/AzureHound)
- [BloodHound 4.2 Azure Refactor](https://specterops.io/blog/2022/08/03/introducing-bloodhound-4-2-the-azure-refactor/)
- [Microsoft Graph API Permissions Reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Azure RBAC Built-in Roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles)

---

## Appendix A: Property-Level Gap Analysis vs BloodHound/AzureHound

> **Last Updated:** 2026-01-07 (Status review completed)
> This section provides a detailed property-by-property comparison between this project and BloodHound/AzureHound.

### A.1 User Properties (AZUser)

| AzureHound (~65 fields) | This Project (~20 fields) |
|------------------------|---------------------------|
| AboutMe | ❌ |
| AccountEnabled | ✅ accountEnabled |
| AgeGroup | ❌ |
| AssignedLicenses | ❌ |
| AssignedPlans | ❌ |
| Birthday | ❌ |
| BusinessPhones | ❌ |
| City | ❌ |
| CompanyName | ❌ |
| ConsentProvidedForMinor | ❌ |
| Country | ❌ |
| CreatedDateTime | ✅ createdDateTime |
| CreationType | ❌ |
| DeletedDateTime | ❌ |
| Department | ❌ |
| DisplayName | ✅ displayName |
| EmployeeHireDate | ❌ |
| EmployeeId | ❌ |
| EmployeeOrgData | ❌ |
| EmployeeType | ❌ |
| ExternalUserState | ✅ externalUserState |
| ExternalUserStateChangeDateTime | ✅ externalUserStateChangeDateTime |
| FaxNumber | ❌ |
| GivenName | ❌ |
| HireDate | ❌ |
| Identities | ❌ |
| ImAddresses | ❌ |
| Interests | ❌ |
| JobTitle | ❌ |
| LastPasswordChangeDateTime | ✅ lastPasswordChangeDateTime |
| LegalAgeGroupClassification | ❌ |
| LicenseAssignmentStates | ❌ |
| Mail | ❌ |
| MailboxSettings | ❌ |
| MailNickname | ❌ |
| MobilePhone | ❌ |
| MySite | ❌ |
| OfficeLocation | ❌ |
| OnPremisesDistinguishedName | ❌ |
| OnPremisesDomainName | ❌ |
| OnPremisesExtensionAttributes | ✅ onPremisesExtensionAttributes |
| OnPremisesImmutableId | ❌ |
| OnPremisesLastSyncDateTime | ❌ |
| OnPremisesProvisioningErrors | ❌ |
| OnPremisesSamAccountName | ✅ onPremisesSamAccountName |
| OnPremisesSecurityIdentifier | ✅ onPremisesSecurityIdentifier |
| OnPremisesSyncEnabled | ✅ onPremisesSyncEnabled |
| OnPremisesUserPrincipalName | ✅ onPremisesUserPrincipalName |
| OtherMails | ❌ |
| PasswordPolicies | ✅ passwordPolicies |
| PasswordProfile | ❌ |
| PastProjects | ❌ |
| PostalCode | ❌ |
| PreferredDataLocation | ❌ |
| PreferredName | ❌ |
| ProvisionedPlans | ❌ |
| ProxyAddresses | ❌ |
| RefreshTokensValidFromDateTime | ✅ refreshTokensValidFromDateTime |
| Responsibilities | ❌ |
| Schools | ❌ |
| ShowInAddressList | ❌ |
| Skills | ❌ |
| SignInSessionsValidFromDateTime | ✅ signInSessionsValidFromDateTime |
| State | ❌ |
| StreetAddress | ❌ |
| Surname | ❌ |
| UsageLocation | ✅ usageLocation |
| UserPrincipalName | ✅ userPrincipalName |
| UserType | ✅ userType |
| ❌ | ✅ **signInActivity** (unique to us) |
| ❌ | ✅ **perUserMfaState** (unique to us) |
| ❌ | ✅ **hasAuthenticator** (unique to us) |
| ❌ | ✅ **hasPhone** (unique to us) |
| ❌ | ✅ **hasFido2** (unique to us) |
| ❌ | ✅ **hasWindowsHello** (unique to us) |
| ❌ | ✅ **hasSoftwareOath** (unique to us) |
| ❌ | ✅ **authMethodCount** (unique to us) |

**Summary:** AzureHound: ~65 fields | We have: ~20 fields + 8 auth method fields = ~28 total. **Gap: ~37 fields.**

---

### A.2 Group Properties (AZGroup)

| AzureHound (~38 fields) | This Project (~15 fields) |
|------------------------|---------------------------|
| AllowExternalSenders | ❌ |
| AssignedLabels | ❌ |
| AssignedLicenses | ❌ |
| AutoSubscribeNewMembers | ❌ |
| Classification | ✅ classification |
| CreatedDateTime | ✅ createdDateTime |
| DeletedDateTime | ✅ deletedDateTime |
| Description | ✅ description |
| DisplayName | ✅ displayName |
| ExpirationDateTime | ❌ |
| GroupTypes | ✅ groupTypes |
| HasMembersWithLicenseErrors | ❌ |
| HideFromAddressLists | ❌ |
| HideFromOutlookClients | ❌ |
| IsAssignableToRole | ✅ isAssignableToRole |
| IsSubscribedByMail | ❌ |
| LicenseProcessingState | ❌ |
| Mail | ✅ mail |
| MailEnabled | ✅ mailEnabled |
| MailNickname | ❌ |
| MembershipRule | ✅ membershipRule |
| MembershipRuleProcessingState | ❌ |
| OnPremisesLastSyncDateTime | ❌ |
| OnPremisesProvisioningErrors | ❌ |
| OnPremisesSamAccountName | ❌ |
| OnPremisesSecurityIdentifier | ✅ onPremisesSecurityIdentifier |
| OnPremisesSyncEnabled | ✅ onPremisesSyncEnabled |
| PreferredDataLocation | ❌ |
| PreferredLanguage | ❌ |
| ProxyAddresses | ❌ |
| RenewedDateTime | ❌ |
| ResourceBehaviorOptions | ❌ |
| ResourceProvisioningOptions | ❌ |
| SecurityEnabled | ✅ securityEnabled |
| SecurityIdentifier | ❌ |
| Theme | ❌ |
| UnseenCount | ❌ |
| Visibility | ✅ visibility |
| ❌ | ✅ **memberCountDirect** (unique to us) |
| ❌ | ✅ **userMemberCount** (unique to us) |
| ❌ | ✅ **groupMemberCount** (unique to us) |
| ❌ | ✅ **servicePrincipalMemberCount** (unique to us) |
| ❌ | ✅ **deviceMemberCount** (unique to us) |

**Summary:** AzureHound: ~38 fields | We have: ~15 fields + 5 member count fields = ~20 total. **Gap: ~18 fields.**

---

### A.3 Service Principal Properties (AZServicePrincipal)

| AzureHound (~32 fields) | This Project (~17 fields) |
|------------------------|---------------------------|
| AccountEnabled | ✅ accountEnabled |
| AddIns | ✅ addIns |
| AlternativeNames | ❌ |
| AppDescription | ❌ |
| AppDisplayName | ✅ appDisplayName |
| AppId | ✅ appId |
| ApplicationTemplateId | ❌ |
| AppOwnerOrganizationId | ❌ |
| AppRoleAssignmentRequired | ✅ appRoleAssignmentRequired |
| AppRoles | ❌ |
| DeletedDateTime | ✅ deletedDateTime |
| Description | ✅ description |
| DisabledByMicrosoftStatus | ❌ |
| DisplayName | ✅ displayName |
| Homepage | ❌ |
| Info | ❌ |
| KeyCredentials | ✅ keyCredentials |
| LoginUrl | ❌ |
| LogoutUrl | ❌ |
| Notes | ✅ notes |
| NotificationEmailAddresses | ❌ |
| OAuth2PermissionScopes | ✅ oauth2PermissionScopes |
| PasswordCredentials | ✅ passwordCredentials |
| PreferredSingleSignOnMode | ❌ |
| ReplyUrls | ❌ |
| SamlSingleSignOnSettings | ❌ |
| ServicePrincipalNames | ✅ servicePrincipalNames |
| ServicePrincipalType | ✅ servicePrincipalType |
| SignInAudience | ❌ |
| Tags | ✅ tags |
| TokenEncryptionKeyId | ❌ |
| VerifiedPublisher | ❌ |
| ❌ | ✅ resourceSpecificApplicationPermissions |
| ❌ | ✅ **secretCount** (unique - credential analytics) |
| ❌ | ✅ **certificateCount** (unique - credential analytics) |
| ❌ | ✅ **expiredSecretsCount** (unique - expiry analysis) |
| ❌ | ✅ **expiringSecretsCount** (unique - 30-day warning) |
| ❌ | ✅ **credentialStatus** per secret (unique) |

**Summary:** AzureHound: ~32 fields | We have: ~17 fields + 5 credential analytics = ~22 total. **Gap: ~10 fields.**

---

### A.4 Application Properties (AZApp)

| AzureHound (~31 fields) | This Project (~12 fields) |
|------------------------|---------------------------|
| AddIns | ❌ |
| Api | ❌ |
| AppId | ✅ appId |
| ApplicationTemplateId | ❌ |
| AppRoles | ❌ |
| CreatedDateTime | ✅ createdDateTime |
| DeletedDateTime | ❌ |
| Description | ❌ |
| DisabledByMicrosoftStatus | ❌ |
| DisplayName | ✅ displayName |
| GroupMembershipClaims | ❌ |
| IdentifierUris | ❌ |
| Info | ❌ |
| IsDeviceOnlyAuthSupported | ❌ |
| IsFallbackPublicClient | ❌ |
| KeyCredentials | ✅ keyCredentials |
| Logo | ❌ |
| Notes | ❌ |
| OAuth2RequiredPostResponse | ❌ |
| OptionalClaims | ❌ |
| ParentalControlSettings | ❌ |
| PasswordCredentials | ✅ passwordCredentials |
| PublicClient | ❌ |
| PublisherDomain | ✅ publisherDomain |
| RequiredResourceAccess | ✅ requiredResourceAccess |
| SignInAudience | ✅ signInAudience |
| SPA | ❌ |
| Tags | ❌ |
| TokenEncryptionKeyId | ❌ |
| VerifiedPublisher | ✅ verifiedPublisher |
| Web | ❌ |
| ❌ | ✅ **federatedIdentityCredentials** (unique - separate API call) |
| ❌ | ✅ **hasFederatedCredentials** (unique) |
| ❌ | ✅ **secretCount** (unique - credential analytics) |
| ❌ | ✅ **certificateCount** (unique - credential analytics) |
| ❌ | ✅ **credentialStatus** per secret (unique - expiry analysis) |
| ❌ | ✅ **apiPermissionCount** (unique) |

**Summary:** AzureHound: ~31 fields | We have: ~12 fields + 6 unique analytics = ~18 total. **Gap: ~13 fields.** However, we have federated identity credentials which AzureHound doesn't fetch.

---

### A.5 Device Properties (AZDevice)

| AzureHound (~22 fields) | This Project (~16 fields) |
|------------------------|---------------------------|
| AccountEnabled | ✅ accountEnabled |
| AlternativeSecurityIds | ❌ |
| ApproximateLastSignInDateTime | ✅ approximateLastSignInDateTime |
| ComplianceExpirationDateTime | ❌ |
| DeviceId | ✅ deviceId |
| DeviceMetadata | ❌ |
| DeviceVersion | ✅ deviceVersion |
| DisplayName | ✅ displayName |
| ExtensionAttributes | ❌ |
| IsCompliant | ✅ isCompliant |
| IsManaged | ✅ isManaged |
| Manufacturer | ✅ manufacturer |
| MdmAppId | ❌ |
| Model | ✅ model |
| OnPremisesLastSyncDateTime | ❌ |
| OnPremisesSyncEnabled | ❌ |
| OperatingSystem | ✅ operatingSystem |
| OperatingSystemVersion | ✅ operatingSystemVersion |
| PhysicalIds | ❌ |
| ProfileType | ✅ profileType |
| SystemLabels | ❌ |
| TrustType | ✅ trustType |
| ❌ | ✅ createdDateTime |
| ❌ | ✅ registrationDateTime |

**Summary:** AzureHound: ~22 fields | We have: ~16 fields. **Gap: ~6 fields.** Closest parity of all entities.

---

### A.6 Relationship/Edge Comparison - REVISED

> **Critical:** BloodHound has ~46 Azure edge types. We have 15. This is a **major gap**.

**BloodHound's 46 Azure Edge Types:**

| Category | Edge Types | We Have? |
|----------|-----------|----------|
| **Basic Membership** | AZMemberOf, AZHasRole | ✅ Yes |
| **PIM** | AZRoleEligible, AZRoleApprover | ✅ Partial |
| **Ownership** | AZOwns, AZOwner | ✅ Yes |
| **Hierarchy** | AZContains, AZScopedTo, AZRunsAs | ✅ Partial |
| **Managed Identity** | AZManagedIdentity, AZNodeResourceGroup | ✅ Partial |
| **Admin Roles** | AZGlobalAdmin, AZAppAdmin, AZCloudAppAdmin, AZPrivilegedAuthAdmin, AZPrivilegedRoleAdmin, AZUserAccessAdministrator | ❌ **No** |
| **Resource Contributor** | AZContributor, AZVMContributor, AZWebsiteContributor, AZAutomationContributor, AZAKSContributor, AZAvereContributor, AZKeyVaultKVContributor, AZLogicAppContributor | ❌ **No** |
| **Key Vault** | AZGetCertificates, AZGetKeys, AZGetSecrets | ✅ Partial (`keyVaultAccess`) |
| **Abuse Capabilities** | AZAddMembers, AZAddOwner, AZAddSecret, AZResetPassword | ❌ **No** |
| **VM/Execution** | AZExecuteCommand, AZVMAdminLogin | ❌ **No** |
| **Graph API Abuse** | AZMGAddMember, AZMGAddOwner, AZMGAddSecret, AZMGGrantAppRoles, AZMGGrantRole | ❌ **No** |
| **API Permission Abuse** | AZMGAppRoleAssignment_ReadWrite_All, AZMGApplication_ReadWrite_All, AZMGDirectory_ReadWrite_All, AZMGGroupMember_ReadWrite_All, AZMGGroup_ReadWrite_All, AZMGRoleManagement_ReadWrite_Directory, AZMGServicePrincipalEndpoint_ReadWrite_All | ❌ **No** |

**What we collect (15 types):**

| Our Relationship | BloodHound Equivalent | Status |
|-----------------|----------------------|--------|
| `groupMember` | AZMemberOf | ✅ Match |
| `groupMemberTransitive` | (computed at query) | ✅ Extra |
| `directoryRole` | AZHasRole | ✅ Match |
| `pimEligible` | AZRoleEligible | ✅ Match |
| `pimActive` | (computed) | ✅ Extra |
| `pimGroupEligible` | (not separate) | ✅ Extra |
| `pimGroupActive` | (not separate) | ✅ Extra |
| `appOwner` | AZOwns | ✅ Match |
| `spOwner` | AZOwns | ✅ Match |
| `groupOwner` | AZOwns | ✅ Match |
| `deviceOwner` | AZOwns | ✅ Match |
| `azureRbac` | AZContributor, etc. | ⚠️ Raw only |
| `oauth2PermissionGrant` | (used for AZMGxxx) | ⚠️ Raw only |
| `appRoleAssignment` | (used for AZMGxxx) | ⚠️ Raw only |
| `license` | ❌ Not in BloodHound | ✅ Extra |
| `contains` | AZContains | ✅ Match |
| `keyVaultAccess` | AZGetSecrets, etc. | ✅ Match |
| `hasManagedIdentity` | AZManagedIdentity | ✅ Match |

**The Critical Gap: Abuse Edge Derivation**

BloodHound doesn't just collect raw relationships - it **derives abuse edges** from the data:

```
Raw: Service Principal X has appRoleAssignment with Application.ReadWrite.All
Derived: X → AZMGApplication_ReadWrite_All → All Apps (can add secrets to any app)
```

We collect the raw `appRoleAssignment` but don't derive the abuse capabilities. This is the core value of BloodHound.

**Summary:** We have ~33% of BloodHound's edge types. The biggest gap is **abuse edge derivation** - we collect the raw data but don't compute attack paths from it.

---

### A.7 Overall Parity Summary (REVISED - Accurate Comparison)

> **Note:** Previous versions of this document overstated our coverage. This section provides an honest comparison based on actual AzureHound source code analysis (January 2026).

| Category | AzureHound/BloodHound | This Project | Actual Status |
|----------|----------------------|--------------|---------------|
| **User Properties** | ~65 fields | ~20 fields | ⚠️ **Gap** - but we have auth methods |
| **Group Properties** | ~38 fields | ~15 fields | ⚠️ **Gap** |
| **SP Properties** | ~32 fields | ~16 fields | ⚠️ **Gap** |
| **App Properties** | ~31 fields | ~20 fields | ⚠️ **Gap** - but we have federated creds |
| **Device Properties** | ~22 fields | ~15 fields | ⚠️ **Gap** |
| **Azure Resource Types** | ~12 types | 6 types | ⚠️ **Partial** |
| **Edge/Relationship Types** | ~46 types | 15 types | 🔴 **Major Gap** |
| **Abuse Edge Derivation** | Built-in (AZMGxxx) | ❌ None | 🔴 **Critical Gap** |
| **Graph Visualization** | Neo4j + Full UI | Dashboard only | 🔴 **Major Gap** |

### What We Have That AzureHound Doesn't

| Feature | AzureHound | This Project | Advantage |
|---------|------------|--------------|-----------|
| **Authentication Methods** | ❌ | ✅ Per-user MFA state, Authenticator, FIDO2, Phone | Security posture |
| **Sign-in Activity** | ❌ | ✅ Last sign-in timestamps | Inactive account detection |
| **Credential Expiry Analysis** | ❌ | ✅ Expired/expiring status | Hygiene monitoring |
| **Transitive Group Membership** | Computed at query | ✅ Pre-computed | Faster queries |
| **License Assignments** | ❌ | ✅ Per-user licenses | Compliance |
| **Delta Change Detection** | ❌ | ✅ Permanent change history | Audit trail |

### Critical Gaps to Address

**🔴 CRITICAL - Abuse Edge Derivation (Phase 1):**
AzureHound derives ~20+ abuse edges that we don't have:
- `AZMGApplication_ReadWrite_All` - Can add secrets to any app
- `AZMGRoleManagement_ReadWrite_Directory` - Can assign any role
- `AZMGGroupMember_ReadWrite_All` - Can add members to any group
- `AZMGDirectory_ReadWrite_All` - Can modify directory objects
- `AZAddSecret`, `AZAddOwner`, `AZAddMembers` - Derived from permissions

**These abuse edges are the core value of BloodHound for attack path discovery.**

**🔴 MAJOR - Missing Raw Properties:**

*Users (missing ~45 fields):*
- AboutMe, AgeGroup, AssignedLicenses, AssignedPlans, Birthday, BusinessPhones
- City, CompanyName, Country, Department, EmployeeHireDate, EmployeeId
- FaxNumber, GivenName, Identities, ImAddresses, JobTitle, Mail
- MailboxSettings, MailNickname, MobilePhone, OfficeLocation, OtherMails
- PostalCode, ProxyAddresses, State, StreetAddress, Surname, and more

*Groups (missing ~23 fields):*
- AllowExternalSenders, AssignedLabels, AssignedLicenses, AutoSubscribeNewMembers
- ExpirationDateTime, HasMembersWithLicenseErrors, HideFromAddressLists
- LicenseProcessingState, PreferredDataLocation, PreferredLanguage
- ResourceBehaviorOptions, ResourceProvisioningOptions, Theme, and more

*Service Principals (missing ~16 fields):*
- AlternativeNames, AppDescription, ApplicationTemplateId, DisabledByMicrosoftStatus
- Homepage, Info, LoginUrl, LogoutUrl, NotificationEmailAddresses
- PreferredSingleSignOnMode, ReplyUrls, SamlSingleSignOnSettings, and more

**⚠️ MEDIUM - Missing Azure Resources (Phase 3):**
- VM Scale Sets, Automation Accounts, Function Apps, Logic Apps
- Web Apps, AKS Clusters, Container Registries, Storage Accounts

### Recommended Priority

1. **Phase 1 (HIGH):** Implement `DeriveAbuseEdges` - This is the core BloodHound value
2. **Phase 1b (MEDIUM):** Add missing raw properties to existing collectors
3. **Phase 3 (LOW):** Add remaining Azure resource types
4. **Phase 4 (LOW):** Graph visualization

### Honest Assessment

**Our Strengths:**
- Security posture analysis (auth methods, MFA state, credential health)
- Change detection and audit trail
- Pre-computed transitive memberships

**Our Weaknesses:**
- No attack path derivation (the main point of BloodHound)
- Missing ~50% of raw property fields
- Only 33% of edge/relationship types

**Conclusion:** This project excels at **security posture monitoring** but is NOT currently a BloodHound replacement for **attack path discovery**. Phase 1 (abuse edge derivation) is critical to close this gap.

---

**End of Roadmap**
