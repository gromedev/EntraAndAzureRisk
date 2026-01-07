# V2 Export Examples

This document shows example JSON records for each container in the V2 unified architecture.

---

## Container: `principals`

All identity objects with `principalType` discriminator.

### User (principalType: "user")

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "objectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "principalType": "user",
  "displayName": "John Doe",
  "userPrincipalName": "john.doe@contoso.com",
  "accountEnabled": true,
  "userType": "Member",
  "createdDateTime": "2023-01-15T10:30:00Z",
  "lastSignInDateTime": "2025-01-06T14:22:33Z",
  "passwordPolicies": "DisablePasswordExpiration",
  "usageLocation": "US",
  "externalUserState": null,
  "externalUserStateChangeDateTime": null,
  "onPremisesSyncEnabled": true,
  "onPremisesSamAccountName": "jdoe",
  "onPremisesUserPrincipalName": "jdoe@contoso.local",
  "onPremisesSecurityIdentifier": "S-1-5-21-123456789-987654321-111111111-1234",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### User with Auth Methods (principalType: "user")

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "objectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "principalType": "user",
  "displayName": "Jane Smith",
  "userPrincipalName": "jane.smith@contoso.com",
  "accountEnabled": true,
  "userType": "Member",
  "authMethods": {
    "perUserMfaState": "enforced",
    "hasAuthenticator": true,
    "hasPhone": true,
    "hasFido2": true,
    "hasEmail": true,
    "hasPassword": true,
    "hasTap": false,
    "hasWindowsHello": true,
    "hasSoftwareOath": false,
    "methodCount": 5,
    "methods": [
      { "type": "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod", "id": "auth-id-1" },
      { "type": "#microsoft.graph.phoneAuthenticationMethod", "id": "phone-id-1" },
      { "type": "#microsoft.graph.fido2AuthenticationMethod", "id": "fido-id-1" }
    ]
  },
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Group (principalType: "group")

```json
{
  "id": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
  "objectId": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
  "principalType": "group",
  "displayName": "Engineering Team",
  "description": "All engineering department members",
  "mail": "engineering@contoso.com",
  "mailNickname": "engineering",
  "mailEnabled": true,
  "securityEnabled": true,
  "groupTypes": ["Unified"],
  "membershipRule": null,
  "membershipRuleProcessingState": null,
  "visibility": "Private",
  "classification": "Internal",
  "isAssignableToRole": false,
  "resourceProvisioningOptions": ["Team"],
  "onPremisesSyncEnabled": false,
  "createdDateTime": "2022-06-01T09:00:00Z",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Service Principal (principalType: "servicePrincipal")

```json
{
  "id": "c3d4e5f6-a7b8-9012-cdef-345678901234",
  "objectId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
  "principalType": "servicePrincipal",
  "displayName": "Contoso API",
  "appId": "d4e5f6a7-b8c9-0123-def4-567890123456",
  "appDisplayName": "Contoso API",
  "servicePrincipalType": "Application",
  "accountEnabled": true,
  "appOwnerOrganizationId": "e5f6a7b8-c9d0-1234-ef56-789012345678",
  "homepage": "https://api.contoso.com",
  "loginUrl": null,
  "logoutUrl": "https://api.contoso.com/logout",
  "replyUrls": ["https://api.contoso.com/callback"],
  "servicePrincipalNames": ["api://contoso-api", "https://api.contoso.com"],
  "tags": ["WindowsAzureActiveDirectoryIntegratedApp"],
  "notificationEmailAddresses": ["admin@contoso.com"],
  "spCredentials": {
    "passwordCredentials": [
      {
        "keyId": "key-id-1",
        "displayName": "Production Secret",
        "startDateTime": "2024-01-01T00:00:00Z",
        "endDateTime": "2026-01-01T00:00:00Z",
        "status": "active"
      }
    ],
    "keyCredentials": [],
    "hasExpiredCredentials": false,
    "hasExpiringCredentials": false,
    "earliestExpiry": "2026-01-01T00:00:00Z"
  },
  "createdDateTime": "2023-03-15T14:00:00Z",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Device (principalType: "device")

```json
{
  "id": "d4e5f6a7-b8c9-0123-def4-567890123456",
  "objectId": "d4e5f6a7-b8c9-0123-def4-567890123456",
  "principalType": "device",
  "displayName": "LAPTOP-JD01",
  "deviceId": "device-guid-12345",
  "operatingSystem": "Windows",
  "operatingSystemVersion": "10.0.22631.2506",
  "trustType": "AzureAd",
  "profileType": "RegisteredDevice",
  "isCompliant": true,
  "isManaged": true,
  "isRooted": false,
  "managementType": "MDM",
  "manufacturer": "Microsoft Corporation",
  "model": "Surface Pro 9",
  "approximateLastSignInDateTime": "2025-01-06T16:45:00Z",
  "registrationDateTime": "2023-08-20T11:30:00Z",
  "createdDateTime": "2023-08-20T11:30:00Z",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Application (principalType: "application")

```json
{
  "id": "e5f6a7b8-c9d0-1234-ef56-789012345678",
  "objectId": "e5f6a7b8-c9d0-1234-ef56-789012345678",
  "principalType": "application",
  "displayName": "My Custom App",
  "appId": "f6a7b8c9-d0e1-2345-f678-901234567890",
  "signInAudience": "AzureADMyOrg",
  "publisherDomain": "contoso.com",
  "identifierUris": ["api://my-custom-app"],
  "web": {
    "redirectUris": ["https://myapp.contoso.com/callback"],
    "logoutUrl": "https://myapp.contoso.com/logout"
  },
  "credentials": {
    "secrets": [
      {
        "keyId": "secret-key-1",
        "displayName": "Dev Secret",
        "startDateTime": "2024-06-01T00:00:00Z",
        "endDateTime": "2025-06-01T00:00:00Z",
        "status": "expiring_soon"
      }
    ],
    "certificates": [
      {
        "keyId": "cert-key-1",
        "displayName": "Production Cert",
        "startDateTime": "2024-01-01T00:00:00Z",
        "endDateTime": "2026-01-01T00:00:00Z",
        "status": "active"
      }
    ],
    "secretCount": 1,
    "certificateCount": 1,
    "hasExpiredCredentials": false,
    "hasExpiringCredentials": true,
    "earliestExpiry": "2025-06-01T00:00:00Z"
  },
  "createdDateTime": "2024-01-10T09:00:00Z",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

---

## Container: `relationships`

All relationships with `relationType` discriminator.

### Group Membership (relationType: "groupMember")

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890_b2c3d4e5-f6a7-8901-bcde-f23456789012_groupMember",
  "objectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890_b2c3d4e5-f6a7-8901-bcde-f23456789012_groupMember",
  "relationType": "groupMember",
  "sourceId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "sourceType": "user",
  "sourceDisplayName": "John Doe",
  "sourceUserPrincipalName": "john.doe@contoso.com",
  "sourceAccountEnabled": true,
  "sourceUserType": "Member",
  "targetId": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
  "targetType": "group",
  "targetDisplayName": "Engineering Team",
  "targetSecurityEnabled": true,
  "targetMailEnabled": true,
  "targetVisibility": "Private",
  "targetIsAssignableToRole": false,
  "membershipType": "Direct",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Directory Role Assignment (relationType: "directoryRole")

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890_role-id-123_directoryRole",
  "objectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890_role-id-123_directoryRole",
  "relationType": "directoryRole",
  "sourceId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "sourceType": "user",
  "sourceDisplayName": "Jane Admin",
  "sourceUserPrincipalName": "jane.admin@contoso.com",
  "targetId": "role-id-123",
  "targetType": "directoryRole",
  "targetDisplayName": "Global Administrator",
  "targetRoleTemplateId": "62e90394-69f5-4237-9190-012177145e10",
  "targetIsPrivileged": true,
  "targetIsBuiltIn": true,
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### PIM Eligible Role (relationType: "pimEligible")

```json
{
  "id": "user-id-456_role-def-789_pimEligible",
  "objectId": "user-id-456_role-def-789_pimEligible",
  "relationType": "pimEligible",
  "assignmentType": "eligible",
  "sourceId": "user-id-456",
  "sourceType": "user",
  "sourceDisplayName": "Bob Manager",
  "targetId": "role-def-789",
  "targetType": "directoryRole",
  "targetDisplayName": "User Administrator",
  "targetRoleTemplateId": "fe930be7-5e62-47db-91af-98c3a49a38b1",
  "targetIsPrivileged": true,
  "memberType": "Direct",
  "status": "Provisioned",
  "scheduleInfo": {
    "startDateTime": "2024-01-01T00:00:00Z",
    "expiration": {
      "type": "afterDateTime",
      "endDateTime": "2025-12-31T23:59:59Z"
    }
  },
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### PIM Active Role (relationType: "pimActive")

```json
{
  "id": "user-id-456_role-def-789_pimActive",
  "objectId": "user-id-456_role-def-789_pimActive",
  "relationType": "pimActive",
  "assignmentType": "active",
  "sourceId": "user-id-456",
  "sourceType": "user",
  "sourceDisplayName": "Bob Manager",
  "targetId": "role-def-789",
  "targetType": "directoryRole",
  "targetDisplayName": "User Administrator",
  "targetRoleTemplateId": "fe930be7-5e62-47db-91af-98c3a49a38b1",
  "targetIsPrivileged": true,
  "memberType": "Direct",
  "status": "Provisioned",
  "scheduleInfo": {
    "startDateTime": "2025-01-07T09:00:00Z",
    "expiration": {
      "type": "afterDuration",
      "duration": "PT8H"
    }
  },
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### PIM Group Eligible (relationType: "pimGroupEligible")

```json
{
  "id": "user-id-789_group-id-456_pimGroupEligible",
  "objectId": "user-id-789_group-id-456_pimGroupEligible",
  "relationType": "pimGroupEligible",
  "accessId": "member",
  "sourceId": "user-id-789",
  "sourceType": "user",
  "sourceDisplayName": "Alice Developer",
  "targetId": "group-id-456",
  "targetType": "group",
  "targetDisplayName": "Privileged Access Group",
  "memberType": "Direct",
  "status": "Provisioned",
  "scheduleInfo": {
    "startDateTime": "2024-06-01T00:00:00Z",
    "expiration": {
      "type": "noExpiration"
    }
  },
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Azure RBAC Assignment (relationType: "azureRbac")

```json
{
  "id": "rbac-assignment-id-123",
  "objectId": "rbac-assignment-id-123",
  "relationType": "azureRbac",
  "sourceId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
  "sourceType": "servicePrincipal",
  "sourceDisplayName": "Contoso API",
  "targetId": "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c",
  "targetType": "azureRole",
  "targetDisplayName": "Contributor",
  "targetRoleDefinitionName": "Contributor",
  "scope": "/subscriptions/sub-id-123/resourceGroups/rg-production",
  "scopeType": "ResourceGroup",
  "scopeDisplayName": "rg-production",
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

---

## Container: `policies`

All policies with `policyType` discriminator.

### Conditional Access Policy (policyType: "conditionalAccess")

```json
{
  "id": "ca-policy-id-123",
  "objectId": "ca-policy-id-123",
  "policyType": "conditionalAccess",
  "displayName": "Require MFA for All Users",
  "state": "enabled",
  "createdDateTime": "2023-05-01T10:00:00Z",
  "modifiedDateTime": "2024-11-15T14:30:00Z",
  "conditions": {
    "users": {
      "includeUsers": ["All"],
      "excludeUsers": ["emergency-access-account-id"],
      "includeGroups": [],
      "excludeGroups": ["break-glass-group-id"]
    },
    "applications": {
      "includeApplications": ["All"],
      "excludeApplications": []
    },
    "clientAppTypes": ["browser", "mobileAppsAndDesktopClients"],
    "platforms": {
      "includePlatforms": ["all"],
      "excludePlatforms": []
    },
    "locations": {
      "includeLocations": ["All"],
      "excludeLocations": ["trusted-locations-id"]
    },
    "signInRiskLevels": [],
    "userRiskLevels": []
  },
  "grantControls": {
    "operator": "OR",
    "builtInControls": ["mfa"],
    "customAuthenticationFactors": [],
    "termsOfUse": []
  },
  "sessionControls": {
    "signInFrequency": {
      "value": 1,
      "type": "days",
      "isEnabled": true
    },
    "persistentBrowser": null
  },
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Role Management Policy (policyType: "roleManagement")

```json
{
  "id": "role-policy-id-456",
  "objectId": "role-policy-id-456",
  "policyType": "roleManagement",
  "displayName": "Global Administrator Policy",
  "description": "Policy for Global Administrator role",
  "isOrganizationDefault": false,
  "scopeId": "/",
  "scopeType": "DirectoryRole",
  "lastModifiedDateTime": "2024-08-20T09:15:00Z",
  "rules": [
    {
      "@odata.type": "#microsoft.graph.unifiedRoleManagementPolicyExpirationRule",
      "id": "Expiration_EndUser_Assignment",
      "isExpirationRequired": true,
      "maximumDuration": "PT8H"
    },
    {
      "@odata.type": "#microsoft.graph.unifiedRoleManagementPolicyApprovalRule",
      "id": "Approval_EndUser_Assignment",
      "setting": {
        "isApprovalRequired": true,
        "approvalStages": [
          {
            "primaryApprovers": [
              { "id": "approver-group-id", "type": "Group" }
            ]
          }
        ]
      }
    }
  ],
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Role Management Policy Assignment (policyType: "roleManagementAssignment")

```json
{
  "id": "policy-assignment-id-789",
  "objectId": "policy-assignment-id-789",
  "policyType": "roleManagementAssignment",
  "policyId": "role-policy-id-456",
  "roleDefinitionId": "62e90394-69f5-4237-9190-012177145e10",
  "scopeId": "/",
  "scopeType": "DirectoryRole",
  "policyDisplayName": "Global Administrator Policy",
  "policyIsOrganizationDefault": false,
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

---

## Container: `events`

All events with `eventType` discriminator. TTL: 90 days.

### Sign-In Event (eventType: "signIn")

```json
{
  "id": "signin-id-abc123",
  "eventType": "signIn",
  "eventDate": "2025-01-07",
  "createdDateTime": "2025-01-07T10:15:33Z",
  "userDisplayName": "John Doe",
  "userPrincipalName": "john.doe@contoso.com",
  "userId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "appId": "app-id-123",
  "appDisplayName": "Microsoft Teams",
  "ipAddress": "203.0.113.45",
  "clientAppUsed": "Browser",
  "isInteractive": true,
  "errorCode": 50076,
  "failureReason": "Due to a configuration change made by your administrator, or because you moved to a new location, you must use multi-factor authentication to access.",
  "additionalDetails": "MFA required",
  "riskLevelAggregated": "none",
  "riskLevelDuringSignIn": "none",
  "riskState": "none",
  "riskDetail": "none",
  "conditionalAccessStatus": "failure",
  "appliedConditionalAccessPolicies": [
    {
      "id": "ca-policy-id-123",
      "displayName": "Require MFA for All Users",
      "result": "failure"
    }
  ],
  "location": {
    "city": "Seattle",
    "state": "Washington",
    "countryOrRegion": "US"
  },
  "deviceDetail": {
    "deviceId": "",
    "displayName": "",
    "operatingSystem": "Windows 11",
    "browser": "Edge 120",
    "isCompliant": null,
    "isManaged": null,
    "trustType": ""
  },
  "resourceDisplayName": "Microsoft Teams",
  "resourceId": "resource-id-456",
  "collectionTimestamp": "2025-01-07T12:00:00Z"
}
```

### Risky Sign-In Event (eventType: "signIn")

```json
{
  "id": "signin-id-risky-789",
  "eventType": "signIn",
  "eventDate": "2025-01-07",
  "createdDateTime": "2025-01-07T03:45:22Z",
  "userDisplayName": "Jane Smith",
  "userPrincipalName": "jane.smith@contoso.com",
  "userId": "user-id-jane",
  "appId": "app-id-456",
  "appDisplayName": "Azure Portal",
  "ipAddress": "198.51.100.123",
  "clientAppUsed": "Browser",
  "isInteractive": true,
  "errorCode": 0,
  "failureReason": "",
  "additionalDetails": "",
  "riskLevelAggregated": "high",
  "riskLevelDuringSignIn": "high",
  "riskState": "atRisk",
  "riskDetail": "unfamiliarFeatures",
  "conditionalAccessStatus": "success",
  "location": {
    "city": "Moscow",
    "state": "",
    "countryOrRegion": "RU"
  },
  "deviceDetail": {
    "operatingSystem": "Linux",
    "browser": "Firefox 121"
  },
  "collectionTimestamp": "2025-01-07T12:00:00Z"
}
```

### Audit Event (eventType: "audit")

```json
{
  "id": "audit-id-def456",
  "eventType": "audit",
  "eventDate": "2025-01-07",
  "activityDateTime": "2025-01-07T09:30:15Z",
  "activityDisplayName": "Add member to role",
  "category": "RoleManagement",
  "correlationId": "correlation-id-789",
  "result": "success",
  "resultReason": "Successfully added member to role",
  "loggedByService": "Core Directory",
  "operationType": "Add",
  "initiatedBy": {
    "user": {
      "id": "admin-user-id",
      "displayName": "Admin User",
      "userPrincipalName": "admin@contoso.com"
    },
    "app": {
      "appId": "",
      "displayName": "",
      "servicePrincipalId": ""
    }
  },
  "targetResources": [
    {
      "id": "target-user-id",
      "displayName": "New Admin",
      "type": "User",
      "userPrincipalName": "newadmin@contoso.com",
      "modifiedProperties": [
        {
          "displayName": "Role.DisplayName",
          "oldValue": null,
          "newValue": "\"Global Administrator\""
        }
      ]
    }
  ],
  "additionalDetails": [],
  "collectionTimestamp": "2025-01-07T12:00:00Z"
}
```

---

## Container: `changes`

Unified audit trail of all entity changes. No TTL (permanent).

### New Entity (changeType: "new")

```json
{
  "id": "change-id-new-123",
  "objectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "changeDate": "2025-01-07",
  "changeType": "new",
  "entityType": "user",
  "displayName": "New Employee",
  "userPrincipalName": "new.employee@contoso.com",
  "changeTimestamp": "2025-01-07T08:00:00Z",
  "snapshotId": "2025-01-07T08-00-00Z",
  "delta": null
}
```

### Modified Entity (changeType: "modified")

```json
{
  "id": "change-id-mod-456",
  "objectId": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
  "changeDate": "2025-01-07",
  "changeType": "modified",
  "entityType": "user",
  "displayName": "John Doe",
  "userPrincipalName": "john.doe@contoso.com",
  "changeTimestamp": "2025-01-07T08:00:00Z",
  "snapshotId": "2025-01-07T08-00-00Z",
  "delta": {
    "accountEnabled": {
      "old": true,
      "new": false
    },
    "lastSignInDateTime": {
      "old": "2025-01-05T10:00:00Z",
      "new": "2025-01-06T14:22:33Z"
    }
  }
}
```

### Deleted Entity (changeType: "deleted")

```json
{
  "id": "change-id-del-789",
  "objectId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
  "changeDate": "2025-01-07",
  "changeType": "deleted",
  "entityType": "servicePrincipal",
  "displayName": "Old App",
  "changeTimestamp": "2025-01-07T08:00:00Z",
  "snapshotId": "2025-01-07T08-00-00Z",
  "delta": null
}
```

---

## Container: `snapshots`

Collection run metadata.

```json
{
  "id": "2025-01-07T08-00-00Z",
  "snapshotDate": "2025-01-07",
  "snapshotTimestamp": "2025-01-07T08:00:00Z",
  "status": "completed",
  "duration": "PT12M45S",
  "collectors": {
    "users": { "count": 1250, "success": true },
    "groups": { "count": 340, "success": true },
    "servicePrincipals": { "count": 890, "success": true },
    "devices": { "count": 2100, "success": true },
    "applications": { "count": 125, "success": true },
    "relationships": { "count": 15600, "success": true },
    "policies": { "count": 45, "success": true },
    "events": { "count": 3200, "success": true }
  },
  "indexers": {
    "principals": { "new": 12, "modified": 45, "deleted": 3, "unchanged": 4315 },
    "relationships": { "new": 28, "modified": 12, "deleted": 5, "unchanged": 15555 },
    "policies": { "new": 0, "modified": 2, "deleted": 0, "unchanged": 43 },
    "events": { "inserted": 3200 }
  }
}
```

---

## Container: `roles`

Reference data for directory roles, Azure roles, and licenses.

### Directory Role (roleType: "directoryRole")

```json
{
  "id": "62e90394-69f5-4237-9190-012177145e10",
  "objectId": "62e90394-69f5-4237-9190-012177145e10",
  "roleType": "directoryRole",
  "displayName": "Global Administrator",
  "description": "Can manage all aspects of Azure AD and Microsoft services that use Azure AD identities.",
  "roleTemplateId": "62e90394-69f5-4237-9190-012177145e10",
  "isBuiltIn": true,
  "isPrivileged": true,
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

### Azure Role (roleType: "azureRole")

```json
{
  "id": "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c",
  "objectId": "b24988ac-6180-42a0-ab88-20f7382dd24c",
  "roleType": "azureRole",
  "displayName": "Contributor",
  "description": "Grants full access to manage all resources, but does not allow you to assign roles in Azure RBAC.",
  "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c",
  "isBuiltIn": true,
  "permissions": [
    {
      "actions": ["*"],
      "notActions": [
        "Microsoft.Authorization/*/Delete",
        "Microsoft.Authorization/*/Write",
        "Microsoft.Authorization/elevateAccess/Action"
      ]
    }
  ],
  "collectionTimestamp": "2025-01-07T08:00:00Z"
}
```

---

## Summary: Container → Data Types

| Container | Discriminator | Values |
|-----------|---------------|--------|
| `principals` | `principalType` | user, group, servicePrincipal, device, application |
| `relationships` | `relationType` | groupMember, directoryRole, pimEligible, pimActive, pimGroupEligible, pimGroupActive, azureRbac |
| `policies` | `policyType` | conditionalAccess, roleManagement, roleManagementAssignment |
| `events` | `eventType` | signIn, audit |
| `changes` | `entityType` | user, group, servicePrincipal, device, application, relationship, policy |
| `snapshots` | - | Collection run metadata |
| `roles` | `roleType` | directoryRole, azureRole, license |
