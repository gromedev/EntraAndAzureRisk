# Centralized Indexer Configurations
# Each entity type has its own configuration for delta indexing
# Used by Invoke-DeltaIndexingWithBinding to reduce code duplication in indexers

@{
    # ============================================
    # USERS
    # ============================================
    users = @{
        EntityType = 'users'
        EntityNameSingular = 'user'
        EntityNamePlural = 'Users'
        CompareFields = @(
            'accountEnabled'
            'userType'
            'lastSignInDateTime'
            'userPrincipalName'
            'displayName'
            'passwordPolicies'
            'usageLocation'
            'externalUserState'
            'externalUserStateChangeDateTime'
            'onPremisesSyncEnabled'
            'onPremisesSamAccountName'
            'onPremisesUserPrincipalName'
            'onPremisesSecurityIdentifier'
            'onPremisesExtensionAttributes'
            'lastPasswordChangeDateTime'
            'signInSessionsValidFromDateTime'
            'refreshTokensValidFromDateTime'
            'deleted'
        )
        ArrayFields = @('authMethodTypes')
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            accountEnabled = 'accountEnabled'
            userType = 'userType'
            createdDateTime = 'createdDateTime'
            lastSignInDateTime = 'lastSignInDateTime'
            displayName = 'displayName'
            passwordPolicies = 'passwordPolicies'
            usageLocation = 'usageLocation'
            externalUserState = 'externalUserState'
            externalUserStateChangeDateTime = 'externalUserStateChangeDateTime'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSamAccountName = 'onPremisesSamAccountName'
            onPremisesUserPrincipalName = 'onPremisesUserPrincipalName'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            onPremisesExtensionAttributes = 'onPremisesExtensionAttributes'
            lastPasswordChangeDateTime = 'lastPasswordChangeDateTime'
            signInSessionsValidFromDateTime = 'signInSessionsValidFromDateTime'
            refreshTokensValidFromDateTime = 'refreshTokensValidFromDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        # Output binding names (from function.json)
        RawOutBinding = 'usersRawOut'
        ChangesOutBinding = 'userChangesOut'
    }

    # ============================================
    # GROUPS
    # ============================================
    groups = @{
        EntityType = 'groups'
        EntityNameSingular = 'group'
        EntityNamePlural = 'Groups'
        CompareFields = @(
            'displayName'
            'classification'
            'description'
            'groupTypes'
            'mailEnabled'
            'membershipRule'
            'securityEnabled'
            'isAssignableToRole'
            'visibility'
            'onPremisesSyncEnabled'
            'mail'
            'deleted'
            # Member statistics
            'memberCountDirect'
            'userMemberCount'
            'groupMemberCount'
            'servicePrincipalMemberCount'
            'deviceMemberCount'
        )
        ArrayFields = @('groupTypes')
        DocumentFields = @{
            displayName = 'displayName'
            classification = 'classification'
            deletedDateTime = 'deletedDateTime'
            description = 'description'
            groupTypes = 'groupTypes'
            mailEnabled = 'mailEnabled'
            membershipRule = 'membershipRule'
            securityEnabled = 'securityEnabled'
            isAssignableToRole = 'isAssignableToRole'
            createdDateTime = 'createdDateTime'
            visibility = 'visibility'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            mail = 'mail'
            # Member statistics
            memberCountDirect = 'memberCountDirect'
            userMemberCount = 'userMemberCount'
            groupMemberCount = 'groupMemberCount'
            servicePrincipalMemberCount = 'servicePrincipalMemberCount'
            deviceMemberCount = 'deviceMemberCount'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'groupsRawOut'
        ChangesOutBinding = 'groupChangesOut'
    }

    # ============================================
    # SERVICE PRINCIPALS
    # ============================================
    servicePrincipals = @{
        EntityType = 'servicePrincipals'
        EntityNameSingular = 'servicePrincipal'
        EntityNamePlural = 'ServicePrincipals'
        CompareFields = @(
            'accountEnabled'
            'appRoleAssignmentRequired'
            'displayName'
            'appDisplayName'
            'servicePrincipalType'
            'description'
            'notes'
            'deletedDateTime'
            'addIns'
            'oauth2PermissionScopes'
            'resourceSpecificApplicationPermissions'
            'servicePrincipalNames'
            'tags'
        )
        ArrayFields = @(
            'addIns'
            'oauth2PermissionScopes'
            'resourceSpecificApplicationPermissions'
            'servicePrincipalNames'
            'tags'
        )
        DocumentFields = @{
            appId = 'appId'
            displayName = 'displayName'
            appDisplayName = 'appDisplayName'
            servicePrincipalType = 'servicePrincipalType'
            accountEnabled = 'accountEnabled'
            appRoleAssignmentRequired = 'appRoleAssignmentRequired'
            deletedDateTime = 'deletedDateTime'
            description = 'description'
            notes = 'notes'
            addIns = 'addIns'
            oauth2PermissionScopes = 'oauth2PermissionScopes'
            resourceSpecificApplicationPermissions = 'resourceSpecificApplicationPermissions'
            servicePrincipalNames = 'servicePrincipalNames'
            tags = 'tags'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $false
        IncludeDeleteMarkers = $false
        RawOutBinding = 'servicePrincipalsRawOut'
        ChangesOutBinding = 'servicePrincipalChangesOut'
    }

    # ============================================
    # RISKY USERS
    # ============================================
    riskyUsers = @{
        EntityType = 'riskyUsers'
        EntityNameSingular = 'riskyUser'
        EntityNamePlural = 'RiskyUsers'
        CompareFields = @(
            'userPrincipalName'
            'userDisplayName'
            'riskLevel'
            'riskState'
            'riskDetail'
            'riskLastUpdatedDateTime'
            'isDeleted'
            'isProcessing'
            'deleted'
        )
        ArrayFields = @()
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            userDisplayName = 'userDisplayName'
            riskLevel = 'riskLevel'
            riskState = 'riskState'
            riskDetail = 'riskDetail'
            riskLastUpdatedDateTime = 'riskLastUpdatedDateTime'
            isDeleted = 'isDeleted'
            isProcessing = 'isProcessing'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'riskyUsersRawOut'
        ChangesOutBinding = 'riskyUserChangesOut'
    }

    # ============================================
    # DEVICES
    # ============================================
    devices = @{
        EntityType = 'devices'
        EntityNameSingular = 'device'
        EntityNamePlural = 'Devices'
        CompareFields = @(
            'displayName'
            'accountEnabled'
            'operatingSystem'
            'operatingSystemVersion'
            'isCompliant'
            'isManaged'
            'trustType'
            'approximateLastSignInDateTime'
            'manufacturer'
            'model'
            'profileType'
            'deleted'
        )
        ArrayFields = @()
        DocumentFields = @{
            displayName = 'displayName'
            deviceId = 'deviceId'
            accountEnabled = 'accountEnabled'
            operatingSystem = 'operatingSystem'
            operatingSystemVersion = 'operatingSystemVersion'
            isCompliant = 'isCompliant'
            isManaged = 'isManaged'
            trustType = 'trustType'
            approximateLastSignInDateTime = 'approximateLastSignInDateTime'
            createdDateTime = 'createdDateTime'
            deviceVersion = 'deviceVersion'
            manufacturer = 'manufacturer'
            model = 'model'
            profileType = 'profileType'
            registrationDateTime = 'registrationDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'devicesRawOut'
        ChangesOutBinding = 'deviceChangesOut'
    }

    # ============================================
    # CONDITIONAL ACCESS POLICIES
    # ============================================
    conditionalAccessPolicies = @{
        EntityType = 'conditionalAccessPolicies'
        EntityNameSingular = 'policy'
        EntityNamePlural = 'Policies'
        CompareFields = @(
            'displayName'
            'state'
            'conditions'
            'grantControls'
            'sessionControls'
            'deleted'
        )
        ArrayFields = @('conditions', 'grantControls', 'sessionControls')
        DocumentFields = @{
            displayName = 'displayName'
            state = 'state'
            createdDateTime = 'createdDateTime'
            modifiedDateTime = 'modifiedDateTime'
            conditions = 'conditions'
            grantControls = 'grantControls'
            sessionControls = 'sessionControls'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'caPoliciesRawOut'
        ChangesOutBinding = 'caPolicyChangesOut'
    }

    # ============================================
    # APP REGISTRATIONS
    # ============================================
    appRegistrations = @{
        EntityType = 'appRegistrations'
        EntityNameSingular = 'appRegistration'
        EntityNamePlural = 'AppRegistrations'
        CompareFields = @(
            'displayName'
            'signInAudience'
            'publisherDomain'
            'passwordCredentials'
            'keyCredentials'
            'secretCount'
            'certificateCount'
            'requiredResourceAccess'
            'apiPermissionCount'
            'verifiedPublisher'
            'isPublisherVerified'
            'federatedIdentityCredentials'
            'hasFederatedCredentials'
            'federatedCredentialCount'
            'deleted'
        )
        ArrayFields = @('passwordCredentials', 'keyCredentials', 'requiredResourceAccess', 'federatedIdentityCredentials')
        DocumentFields = @{
            appId = 'appId'
            displayName = 'displayName'
            createdDateTime = 'createdDateTime'
            signInAudience = 'signInAudience'
            publisherDomain = 'publisherDomain'
            passwordCredentials = 'passwordCredentials'
            keyCredentials = 'keyCredentials'
            secretCount = 'secretCount'
            certificateCount = 'certificateCount'
            requiredResourceAccess = 'requiredResourceAccess'
            apiPermissionCount = 'apiPermissionCount'
            verifiedPublisher = 'verifiedPublisher'
            isPublisherVerified = 'isPublisherVerified'
            federatedIdentityCredentials = 'federatedIdentityCredentials'
            hasFederatedCredentials = 'hasFederatedCredentials'
            federatedCredentialCount = 'federatedCredentialCount'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'appRegistrationsRawOut'
        ChangesOutBinding = 'appRegistrationChangesOut'
    }

    # ============================================
    # DIRECTORY ROLES
    # ============================================
    directoryRoles = @{
        EntityType = 'directoryRoles'
        EntityNameSingular = 'directoryRole'
        EntityNamePlural = 'DirectoryRoles'
        CompareFields = @(
            'displayName'
            'description'
            'roleTemplateId'
            'isPrivileged'
            'memberCount'
            'members'
            'deleted'
        )
        ArrayFields = @('members')
        DocumentFields = @{
            displayName = 'displayName'
            description = 'description'
            roleTemplateId = 'roleTemplateId'
            isPrivileged = 'isPrivileged'
            memberCount = 'memberCount'
            members = 'members'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'directoryRolesRawOut'
        ChangesOutBinding = 'directoryRoleChangesOut'
    }

    # ============================================
    # USER AUTH METHODS
    # ============================================
    userAuthMethods = @{
        EntityType = 'userAuthMethods'
        EntityNameSingular = 'userAuthMethod'
        EntityNamePlural = 'UserAuthMethods'
        CompareFields = @(
            'perUserMfaState'
            'hasAuthenticator'
            'hasPhone'
            'hasFido2'
            'hasEmail'
            'hasPassword'
            'hasTap'
            'hasWindowsHello'
            'methodCount'
            'methods'
            'deleted'
        )
        ArrayFields = @('methods')
        DocumentFields = @{
            userPrincipalName = 'userPrincipalName'
            displayName = 'displayName'
            accountEnabled = 'accountEnabled'
            perUserMfaState = 'perUserMfaState'
            hasAuthenticator = 'hasAuthenticator'
            hasPhone = 'hasPhone'
            hasFido2 = 'hasFido2'
            hasEmail = 'hasEmail'
            hasPassword = 'hasPassword'
            hasTap = 'hasTap'
            hasWindowsHello = 'hasWindowsHello'
            methodCount = 'methodCount'
            methods = 'methods'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $false
        IncludeDeleteMarkers = $false
        RawOutBinding = 'userAuthMethodsRawOut'
        ChangesOutBinding = 'userAuthMethodChangesOut'
    }

    # ============================================
    # PIM ROLE ASSIGNMENTS
    # ============================================
    pimRoles = @{
        EntityType = 'pimRoles'
        EntityNameSingular = 'pimRole'
        EntityNamePlural = 'PimRoles'
        CompareFields = @(
            'assignmentType'
            'principalId'
            'roleDefinitionId'
            'roleDefinitionName'
            'principalDisplayName'
            'principalType'
            'memberType'
            'status'
            'scheduleInfo'
            'deleted'
        )
        ArrayFields = @('scheduleInfo')
        DocumentFields = @{
            assignmentType = 'assignmentType'
            principalId = 'principalId'
            roleDefinitionId = 'roleDefinitionId'
            roleDefinitionName = 'roleDefinitionName'
            roleTemplateId = 'roleTemplateId'
            principalDisplayName = 'principalDisplayName'
            principalType = 'principalType'
            memberType = 'memberType'
            status = 'status'
            scheduleInfo = 'scheduleInfo'
            createdDateTime = 'createdDateTime'
            modifiedDateTime = 'modifiedDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'pimRolesRawOut'
        ChangesOutBinding = 'pimRoleChangesOut'
    }

    # ============================================
    # PIM GROUP MEMBERSHIPS
    # ============================================
    pimGroups = @{
        EntityType = 'pimGroups'
        EntityNameSingular = 'pimGroup'
        EntityNamePlural = 'PimGroups'
        CompareFields = @(
            'assignmentType'
            'principalId'
            'groupId'
            'groupDisplayName'
            'accessId'
            'principalDisplayName'
            'principalType'
            'memberType'
            'status'
            'scheduleInfo'
            'deleted'
        )
        ArrayFields = @('scheduleInfo')
        DocumentFields = @{
            assignmentType = 'assignmentType'
            principalId = 'principalId'
            groupId = 'groupId'
            groupDisplayName = 'groupDisplayName'
            accessId = 'accessId'
            principalDisplayName = 'principalDisplayName'
            principalType = 'principalType'
            memberType = 'memberType'
            status = 'status'
            scheduleInfo = 'scheduleInfo'
            createdDateTime = 'createdDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'pimGroupsRawOut'
        ChangesOutBinding = 'pimGroupChangesOut'
    }

    # ============================================
    # ROLE POLICIES
    # ============================================
    rolePolicies = @{
        EntityType = 'rolePolicies'
        EntityNameSingular = 'rolePolicy'
        EntityNamePlural = 'RolePolicies'
        CompareFields = @(
            'displayName'
            'scopeId'
            'scopeType'
            'rules'
            'effectiveRules'
            'deleted'
        )
        ArrayFields = @('rules', 'effectiveRules')
        DocumentFields = @{
            displayName = 'displayName'
            scopeId = 'scopeId'
            scopeType = 'scopeType'
            rules = 'rules'
            effectiveRules = 'effectiveRules'
            lastModifiedDateTime = 'lastModifiedDateTime'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'rolePoliciesRawOut'
        ChangesOutBinding = 'rolePolicyChangesOut'
    }

    # ============================================
    # AZURE RBAC ASSIGNMENTS
    # ============================================
    azureRbac = @{
        EntityType = 'azureRbac'
        EntityNameSingular = 'rbacAssignment'
        EntityNamePlural = 'RbacAssignments'
        CompareFields = @(
            'principalId'
            'principalType'
            'roleDefinitionId'
            'roleDefinitionName'
            'scope'
            'scopeType'
            'condition'
            'deleted'
        )
        ArrayFields = @()
        DocumentFields = @{
            principalId = 'principalId'
            principalType = 'principalType'
            roleDefinitionId = 'roleDefinitionId'
            roleDefinitionName = 'roleDefinitionName'
            scope = 'scope'
            scopeType = 'scopeType'
            scopeDisplayName = 'scopeDisplayName'
            condition = 'condition'
            createdOn = 'createdOn'
            updatedOn = 'updatedOn'
            collectionTimestamp = 'collectionTimestamp'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'azureRbacRawOut'
        ChangesOutBinding = 'azureRbacChangesOut'
    }

    # ============================================
    # ============================================
    # UNIFIED CONTAINERS (V2 Architecture)
    # ============================================
    # ============================================

    # ============================================
    # PRINCIPALS (Unified: users, groups, SPs, apps, devices)
    # ============================================
    principals = @{
        EntityType = 'principals'
        EntityNameSingular = 'principal'
        EntityNamePlural = 'Principals'
        # NOTE: Only include fields that are ACTUALLY COLLECTED by the collectors
        # See: CollectUsersWithAuthMethods, CollectEntraGroups, CollectEntraServicePrincipals,
        #      CollectDevices, CollectAppRegistrations
        CompareFields = @(
            # Common fields (all principal types)
            'principalType'
            'displayName'
            'accountEnabled'
            'deleted'
            'createdDateTime'

            # User-specific fields (from CollectUsersWithAuthMethods)
            'userPrincipalName'
            'userType'
            'lastSignInDateTime'
            'passwordPolicies'
            'usageLocation'
            'externalUserState'
            'externalUserStateChangeDateTime'
            'onPremisesSyncEnabled'
            'onPremisesSamAccountName'
            'onPremisesUserPrincipalName'
            'onPremisesSecurityIdentifier'
            'onPremisesExtensionAttributes'
            # Password and session timestamps (security analytics)
            'lastPasswordChangeDateTime'
            'signInSessionsValidFromDateTime'
            'refreshTokensValidFromDateTime'
            # User auth methods (embedded in user - from CollectUsersWithAuthMethods)
            'perUserMfaState'
            'hasAuthenticator'
            'hasPhone'
            'hasFido2'
            'hasEmail'
            'hasPassword'
            'hasTap'
            'hasWindowsHello'
            'hasSoftwareOath'
            'authMethodCount'
            'authMethodTypes'

            # Group-specific fields (from CollectEntraGroups)
            'securityEnabled'
            'mailEnabled'
            'mail'
            'groupTypes'
            'membershipRule'
            'isAssignableToRole'
            'visibility'
            'classification'
            'description'
            'deletedDateTime'
            # Group member statistics (from CollectEntraGroups)
            'memberCountDirect'
            'userMemberCount'
            'groupMemberCount'
            'servicePrincipalMemberCount'
            'deviceMemberCount'

            # ServicePrincipal-specific fields (from CollectEntraServicePrincipals)
            'appId'
            'appDisplayName'
            'servicePrincipalType'
            'appRoleAssignmentRequired'
            'servicePrincipalNames'
            'tags'
            'notes'
            'addIns'
            'oauth2PermissionScopes'
            'resourceSpecificApplicationPermissions'

            # Application-specific fields (from CollectAppRegistrations)
            'signInAudience'
            'publisherDomain'
            'keyCredentials'
            'passwordCredentials'
            'secretCount'
            'certificateCount'
            # API permissions and federated credentials (from CollectAppRegistrations)
            'requiredResourceAccess'
            'apiPermissionCount'
            'verifiedPublisher'
            'isPublisherVerified'
            'federatedIdentityCredentials'
            'hasFederatedCredentials'
            'federatedCredentialCount'

            # Device-specific fields (from CollectDevices)
            'deviceId'
            'operatingSystem'
            'operatingSystemVersion'
            'isCompliant'
            'isManaged'
            'trustType'
            'profileType'
            'manufacturer'
            'model'
            'deviceVersion'
            'approximateLastSignInDateTime'
            'registrationDateTime'
        )
        ArrayFields = @(
            'groupTypes'
            'servicePrincipalNames'
            'tags'
            'addIns'
            'oauth2PermissionScopes'
            'resourceSpecificApplicationPermissions'
            'keyCredentials'
            'passwordCredentials'
            'authMethodTypes'
            'requiredResourceAccess'
            'federatedIdentityCredentials'
        )
        EmbeddedObjectFields = @()
        DocumentFields = @{
            # Common fields
            principalType = 'principalType'
            displayName = 'displayName'
            accountEnabled = 'accountEnabled'
            createdDateTime = 'createdDateTime'
            deletedDateTime = 'deletedDateTime'
            collectionTimestamp = 'collectionTimestamp'

            # User fields (from CollectUsersWithAuthMethods)
            userPrincipalName = 'userPrincipalName'
            userType = 'userType'
            lastSignInDateTime = 'lastSignInDateTime'
            passwordPolicies = 'passwordPolicies'
            usageLocation = 'usageLocation'
            externalUserState = 'externalUserState'
            externalUserStateChangeDateTime = 'externalUserStateChangeDateTime'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSamAccountName = 'onPremisesSamAccountName'
            onPremisesUserPrincipalName = 'onPremisesUserPrincipalName'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            onPremisesExtensionAttributes = 'onPremisesExtensionAttributes'
            # Password and session timestamps (security analytics)
            lastPasswordChangeDateTime = 'lastPasswordChangeDateTime'
            signInSessionsValidFromDateTime = 'signInSessionsValidFromDateTime'
            refreshTokensValidFromDateTime = 'refreshTokensValidFromDateTime'
            # User auth methods (embedded - from CollectUsersWithAuthMethods)
            perUserMfaState = 'perUserMfaState'
            hasAuthenticator = 'hasAuthenticator'
            hasPhone = 'hasPhone'
            hasFido2 = 'hasFido2'
            hasEmail = 'hasEmail'
            hasPassword = 'hasPassword'
            hasTap = 'hasTap'
            hasWindowsHello = 'hasWindowsHello'
            hasSoftwareOath = 'hasSoftwareOath'
            authMethodCount = 'authMethodCount'
            authMethodTypes = 'authMethodTypes'

            # Group fields (from CollectEntraGroups)
            description = 'description'
            securityEnabled = 'securityEnabled'
            mailEnabled = 'mailEnabled'
            mail = 'mail'
            groupTypes = 'groupTypes'
            membershipRule = 'membershipRule'
            isAssignableToRole = 'isAssignableToRole'
            visibility = 'visibility'
            classification = 'classification'
            # Group member statistics
            memberCountDirect = 'memberCountDirect'
            userMemberCount = 'userMemberCount'
            groupMemberCount = 'groupMemberCount'
            servicePrincipalMemberCount = 'servicePrincipalMemberCount'
            deviceMemberCount = 'deviceMemberCount'

            # ServicePrincipal fields (from CollectEntraServicePrincipals)
            appId = 'appId'
            appDisplayName = 'appDisplayName'
            servicePrincipalType = 'servicePrincipalType'
            appRoleAssignmentRequired = 'appRoleAssignmentRequired'
            servicePrincipalNames = 'servicePrincipalNames'
            tags = 'tags'
            notes = 'notes'
            addIns = 'addIns'
            oauth2PermissionScopes = 'oauth2PermissionScopes'
            resourceSpecificApplicationPermissions = 'resourceSpecificApplicationPermissions'

            # Application fields (from CollectAppRegistrations)
            signInAudience = 'signInAudience'
            publisherDomain = 'publisherDomain'
            keyCredentials = 'keyCredentials'
            passwordCredentials = 'passwordCredentials'
            secretCount = 'secretCount'
            certificateCount = 'certificateCount'
            # API permissions and federated credentials
            requiredResourceAccess = 'requiredResourceAccess'
            apiPermissionCount = 'apiPermissionCount'
            verifiedPublisher = 'verifiedPublisher'
            isPublisherVerified = 'isPublisherVerified'
            federatedIdentityCredentials = 'federatedIdentityCredentials'
            hasFederatedCredentials = 'hasFederatedCredentials'
            federatedCredentialCount = 'federatedCredentialCount'

            # Device fields (from CollectDevices)
            deviceId = 'deviceId'
            operatingSystem = 'operatingSystem'
            operatingSystemVersion = 'operatingSystemVersion'
            isCompliant = 'isCompliant'
            isManaged = 'isManaged'
            trustType = 'trustType'
            profileType = 'profileType'
            manufacturer = 'manufacturer'
            model = 'model'
            deviceVersion = 'deviceVersion'
            approximateLastSignInDateTime = 'approximateLastSignInDateTime'
            registrationDateTime = 'registrationDateTime'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'principalsRawOut'
        ChangesOutBinding = 'principalChangesOut'
    }

    # ============================================
    # RELATIONSHIPS (Unified: memberships, roles, permissions)
    # ============================================
    relationships = @{
        EntityType = 'relationships'
        EntityNameSingular = 'relationship'
        EntityNamePlural = 'Relationships'
        # Note: For relationships, the composite key is sourceId_targetId_relationType
        # The objectId field is set to this composite key
        CompareFields = @(
            # Core relationship fields
            'relationType'
            'sourceId'
            'sourceType'
            'sourceDisplayName'
            'targetId'
            'targetType'
            'targetDisplayName'
            'deleted'

            # Denormalized source fields (for Power BI filtering)
            'sourceUserPrincipalName'
            'sourceAccountEnabled'
            'sourceUserType'
            'sourceAppId'
            'sourceServicePrincipalType'
            'sourceSecurityEnabled'

            # Denormalized target fields
            'targetSecurityEnabled'
            'targetMailEnabled'
            'targetVisibility'
            'targetIsAssignableToRole'
            'targetRoleTemplateId'
            'targetIsPrivileged'
            'targetIsBuiltIn'
            'targetRoleDefinitionId'
            'targetRoleDefinitionName'
            'scope'
            'scopeType'
            'scopeDisplayName'

            # Relationship-specific fields
            'membershipType'
            'inheritancePath'
            'inheritanceDepth'
            'assignmentType'
            'memberType'
            'status'
            'scheduleInfo'
            'appRoleId'
            'appRoleDisplayName'
            'resourceId'
            'resourceDisplayName'
            'consentType'
            'permissionScope'

            # Ownership-specific target fields
            'targetAppId'
            'targetSignInAudience'
            'targetPublisherDomain'
            'targetAppDisplayName'
            'targetServicePrincipalType'
            'targetAccountEnabled'
        )
        ArrayFields = @(
            'inheritancePath'
        )
        EmbeddedObjectFields = @(
            'scheduleInfo'
        )
        DocumentFields = @{
            # Core fields
            relationType = 'relationType'
            sourceId = 'sourceId'
            sourceType = 'sourceType'
            sourceDisplayName = 'sourceDisplayName'
            targetId = 'targetId'
            targetType = 'targetType'
            targetDisplayName = 'targetDisplayName'
            collectionTimestamp = 'collectionTimestamp'

            # Denormalized source fields
            sourceUserPrincipalName = 'sourceUserPrincipalName'
            sourceAccountEnabled = 'sourceAccountEnabled'
            sourceUserType = 'sourceUserType'
            sourceAppId = 'sourceAppId'
            sourceServicePrincipalType = 'sourceServicePrincipalType'
            sourceSecurityEnabled = 'sourceSecurityEnabled'
            sourceMailEnabled = 'sourceMailEnabled'
            sourceIsAssignableToRole = 'sourceIsAssignableToRole'

            # Denormalized target fields
            targetSecurityEnabled = 'targetSecurityEnabled'
            targetMailEnabled = 'targetMailEnabled'
            targetVisibility = 'targetVisibility'
            targetIsAssignableToRole = 'targetIsAssignableToRole'
            targetRoleTemplateId = 'targetRoleTemplateId'
            targetIsPrivileged = 'targetIsPrivileged'
            targetIsBuiltIn = 'targetIsBuiltIn'
            targetRoleDefinitionId = 'targetRoleDefinitionId'
            targetRoleDefinitionName = 'targetRoleDefinitionName'
            scope = 'scope'
            scopeType = 'scopeType'
            scopeDisplayName = 'scopeDisplayName'
            targetSkuId = 'targetSkuId'
            targetSkuPartNumber = 'targetSkuPartNumber'

            # Relationship-specific fields
            membershipType = 'membershipType'
            inheritancePath = 'inheritancePath'
            inheritanceDepth = 'inheritanceDepth'
            assignmentType = 'assignmentType'
            memberType = 'memberType'
            status = 'status'
            scheduleInfo = 'scheduleInfo'
            appRoleId = 'appRoleId'
            appRoleDisplayName = 'appRoleDisplayName'
            appRoleDescription = 'appRoleDescription'
            resourceId = 'resourceId'
            resourceDisplayName = 'resourceDisplayName'
            consentType = 'consentType'
            permissionScope = 'permissionScope'
            assignmentSource = 'assignmentSource'
            inheritedFromGroupId = 'inheritedFromGroupId'
            inheritedFromGroupName = 'inheritedFromGroupName'

            # Ownership-specific target fields
            targetAppId = 'targetAppId'
            targetSignInAudience = 'targetSignInAudience'
            targetPublisherDomain = 'targetPublisherDomain'
            targetAppDisplayName = 'targetAppDisplayName'
            targetServicePrincipalType = 'targetServicePrincipalType'
            targetAccountEnabled = 'targetAccountEnabled'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'relationshipsRawOut'
        ChangesOutBinding = 'relationshipChangesOut'
    }

    # ============================================
    # POLICIES (Unified: CA policies, role policies, named locations)
    # ============================================
    policies = @{
        EntityType = 'policies'
        EntityNameSingular = 'policy'
        EntityNamePlural = 'Policies'
        CompareFields = @(
            # Common fields
            'policyType'
            'displayName'
            'description'
            'deleted'

            # CA Policy fields
            'state'
            'conditions'
            'grantControls'
            'sessionControls'

            # Role Policy fields
            'scopeId'
            'scopeType'
            'rules'
            'effectiveRules'

            # Named Location fields (policyType = 'namedLocation')
            'locationType'
            'isTrusted'
            'ipRanges'
            'ipRangeCount'
            'countriesAndRegions'
            'countryLookupMethod'
            'includeUnknownCountriesAndRegions'
        )
        ArrayFields = @(
            'conditions'
            'grantControls'
            'sessionControls'
            'rules'
            'effectiveRules'
            'ipRanges'
            'countriesAndRegions'
        )
        EmbeddedObjectFields = @(
            'conditions'
            'grantControls'
            'sessionControls'
        )
        DocumentFields = @{
            # Common fields
            policyType = 'policyType'
            displayName = 'displayName'
            description = 'description'
            createdDateTime = 'createdDateTime'
            modifiedDateTime = 'modifiedDateTime'
            lastModifiedDateTime = 'lastModifiedDateTime'
            collectionTimestamp = 'collectionTimestamp'

            # CA Policy fields
            state = 'state'
            conditions = 'conditions'
            grantControls = 'grantControls'
            sessionControls = 'sessionControls'

            # Role Policy fields
            scopeId = 'scopeId'
            scopeType = 'scopeType'
            rules = 'rules'
            effectiveRules = 'effectiveRules'

            # Named Location fields (policyType = 'namedLocation')
            locationType = 'locationType'
            isTrusted = 'isTrusted'
            ipRanges = 'ipRanges'
            ipRangeCount = 'ipRangeCount'
            countriesAndRegions = 'countriesAndRegions'
            countryLookupMethod = 'countryLookupMethod'
            includeUnknownCountriesAndRegions = 'includeUnknownCountriesAndRegions'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'policiesRawOut'
        ChangesOutBinding = 'policyChangesOut'
    }

    # ============================================
    # EVENTS (Unified: sign-ins, audits)
    # ============================================
    events = @{
        EntityType = 'events'
        EntityNameSingular = 'event'
        EntityNamePlural = 'Events'
        # Events are append-only, no delta detection
        # Partition key is /eventDate for time-range queries
        CompareFields = @()
        ArrayFields = @()
        EmbeddedObjectFields = @(
            'status'
            'location'
            'deviceDetail'
            'appliedConditionalAccessPolicies'
            'targetResources'
            'initiatedBy'
        )
        DocumentFields = @{
            # Common fields
            eventType = 'eventType'
            eventDate = 'eventDate'
            createdDateTime = 'createdDateTime'
            collectionTimestamp = 'collectionTimestamp'

            # Sign-in fields
            userDisplayName = 'userDisplayName'
            userPrincipalName = 'userPrincipalName'
            userId = 'userId'
            appDisplayName = 'appDisplayName'
            appId = 'appId'
            ipAddress = 'ipAddress'
            clientAppUsed = 'clientAppUsed'
            conditionalAccessStatus = 'conditionalAccessStatus'
            isInteractive = 'isInteractive'
            riskDetail = 'riskDetail'
            riskLevelAggregated = 'riskLevelAggregated'
            riskLevelDuringSignIn = 'riskLevelDuringSignIn'
            riskState = 'riskState'
            resourceDisplayName = 'resourceDisplayName'
            resourceId = 'resourceId'
            status = 'status'
            location = 'location'
            deviceDetail = 'deviceDetail'
            appliedConditionalAccessPolicies = 'appliedConditionalAccessPolicies'

            # Audit fields
            activityDisplayName = 'activityDisplayName'
            activityDateTime = 'activityDateTime'
            operationType = 'operationType'
            result = 'result'
            resultReason = 'resultReason'
            loggedByService = 'loggedByService'
            category = 'category'
            correlationId = 'correlationId'
            targetResources = 'targetResources'
            initiatedBy = 'initiatedBy'
        }
        WriteDeletes = $false
        IncludeDeleteMarkers = $false
        # Events are append-only, no change tracking
        RawOutBinding = 'eventsRawOut'
        ChangesOutBinding = $null
    }

    # ============================================
    # CHANGES (Unified change log - NO TTL)
    # ============================================
    changes = @{
        EntityType = 'changes'
        EntityNameSingular = 'change'
        EntityNamePlural = 'Changes'
        # Changes are write-only, no delta detection needed
        # Partition key is /changeDate for time-range queries
        CompareFields = @()
        ArrayFields = @()
        DocumentFields = @{
            changeDate = 'changeDate'
            changeTimestamp = 'changeTimestamp'
            snapshotId = 'snapshotId'
            entityType = 'entityType'
            entitySubType = 'entitySubType'
            changeType = 'changeType'
            objectId = 'objectId'
            principalType = 'principalType'
            displayName = 'displayName'
            sourceId = 'sourceId'
            targetId = 'targetId'
            relationType = 'relationType'
            delta = 'delta'
            auditCorrelation = 'auditCorrelation'
        }
        WriteDeletes = $false
        IncludeDeleteMarkers = $false
        # No TTL on changes - permanent history
        RawOutBinding = 'changesOut'
        ChangesOutBinding = $null
    }

    # ============================================
    # AZURE RESOURCES (Phase 2: Hierarchy, Key Vaults, VMs)
    # ============================================
    azureResources = @{
        EntityType = 'azureResources'
        EntityNameSingular = 'azureResource'
        EntityNamePlural = 'AzureResources'
        # Partition key is /resourceType for efficient queries
        CompareFields = @(
            # Common fields
            'resourceType'
            'displayName'
            'location'
            'subscriptionId'
            'resourceGroupName'
            'tags'

            # Tenant fields
            'tenantType'
            'defaultDomain'
            'verifiedDomains'

            # Management Group fields
            'managementGroupId'
            'parentId'
            'childCount'

            # Subscription fields
            'state'
            'authorizationSource'

            # Resource Group fields
            'provisioningState'
            'managedBy'

            # Key Vault fields
            'vaultUri'
            'sku'
            'enableRbacAuthorization'
            'enableSoftDelete'
            'enablePurgeProtection'
            'softDeleteRetentionInDays'
            'publicNetworkAccess'
            'networkAcls'
            'accessPolicies'
            'accessPolicyCount'
            'privateEndpointConnections'

            # VM fields
            'vmId'
            'vmSize'
            'zones'
            'osType'
            'osName'
            'computerName'
            'powerState'
            'identityType'
            'hasSystemAssignedIdentity'
            'systemAssignedPrincipalId'
            'hasUserAssignedIdentity'
            'userAssignedIdentities'
            'userAssignedIdentityCount'
            'networkInterfaces'
            'networkInterfaceCount'
        )
        ArrayFields = @(
            'verifiedDomains'
            'managedByTenants'
            'accessPolicies'
            'privateEndpointConnections'
            'zones'
            'userAssignedIdentities'
            'networkInterfaces'
            'technicalNotificationMails'
            'securityComplianceNotificationMails'
        )
        EmbeddedObjectFields = @(
            'sku'
            'networkAcls'
        )
        DocumentFields = @{
            # Common fields
            resourceType = 'resourceType'
            displayName = 'displayName'
            name = 'name'
            location = 'location'
            subscriptionId = 'subscriptionId'
            resourceGroupName = 'resourceGroupName'
            resourceGroupId = 'resourceGroupId'
            tenantId = 'tenantId'
            tags = 'tags'
            collectionTimestamp = 'collectionTimestamp'

            # Tenant fields
            tenantType = 'tenantType'
            defaultDomain = 'defaultDomain'
            verifiedDomains = 'verifiedDomains'
            technicalNotificationMails = 'technicalNotificationMails'
            securityComplianceNotificationMails = 'securityComplianceNotificationMails'

            # Management Group fields
            managementGroupId = 'managementGroupId'
            parentId = 'parentId'
            parentDisplayName = 'parentDisplayName'
            childCount = 'childCount'

            # Subscription fields
            state = 'state'
            authorizationSource = 'authorizationSource'
            managedByTenants = 'managedByTenants'

            # Resource Group fields
            provisioningState = 'provisioningState'
            managedBy = 'managedBy'

            # Key Vault fields
            vaultUri = 'vaultUri'
            sku = 'sku'
            enableRbacAuthorization = 'enableRbacAuthorization'
            enableSoftDelete = 'enableSoftDelete'
            enablePurgeProtection = 'enablePurgeProtection'
            softDeleteRetentionInDays = 'softDeleteRetentionInDays'
            publicNetworkAccess = 'publicNetworkAccess'
            enabledForDeployment = 'enabledForDeployment'
            enabledForDiskEncryption = 'enabledForDiskEncryption'
            enabledForTemplateDeployment = 'enabledForTemplateDeployment'
            networkAcls = 'networkAcls'
            accessPolicies = 'accessPolicies'
            accessPolicyCount = 'accessPolicyCount'
            privateEndpointConnections = 'privateEndpointConnections'

            # VM fields
            vmId = 'vmId'
            vmSize = 'vmSize'
            zones = 'zones'
            osType = 'osType'
            osName = 'osName'
            computerName = 'computerName'
            powerState = 'powerState'
            identityType = 'identityType'
            hasSystemAssignedIdentity = 'hasSystemAssignedIdentity'
            systemAssignedPrincipalId = 'systemAssignedPrincipalId'
            systemAssignedTenantId = 'systemAssignedTenantId'
            hasUserAssignedIdentity = 'hasUserAssignedIdentity'
            userAssignedIdentities = 'userAssignedIdentities'
            userAssignedIdentityCount = 'userAssignedIdentityCount'
            networkInterfaces = 'networkInterfaces'
            networkInterfaceCount = 'networkInterfaceCount'
            adminUsername = 'adminUsername'
            disablePasswordAuthentication = 'disablePasswordAuthentication'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'azureResourcesRawOut'
        ChangesOutBinding = 'azureResourceChangesOut'
    }

    # ============================================
    # AZURE RELATIONSHIPS (Phase 2: Contains, Access, Identity)
    # ============================================
    azureRelationships = @{
        EntityType = 'azureRelationships'
        EntityNameSingular = 'azureRelationship'
        EntityNamePlural = 'AzureRelationships'
        # Partition key is /sourceId for efficient traversal
        CompareFields = @(
            'relationType'
            'sourceType'
            'sourceDisplayName'
            'targetType'
            'targetDisplayName'

            # Contains relationship fields
            'targetLocation'
            'targetSubscriptionId'

            # Key Vault access fields
            'accessType'
            'keyPermissions'
            'secretPermissions'
            'certificatePermissions'
            'storagePermissions'
            'canGetSecrets'
            'canListSecrets'
            'canSetSecrets'
            'canGetKeys'
            'canDecryptWithKey'
            'canGetCertificates'

            # Managed Identity fields
            'identityType'
            'userAssignedIdentityId'
        )
        ArrayFields = @(
            'keyPermissions'
            'secretPermissions'
            'certificatePermissions'
            'storagePermissions'
        )
        DocumentFields = @{
            # Common fields
            relationType = 'relationType'
            sourceId = 'sourceId'
            sourceType = 'sourceType'
            sourceDisplayName = 'sourceDisplayName'
            targetId = 'targetId'
            targetType = 'targetType'
            targetDisplayName = 'targetDisplayName'
            collectionTimestamp = 'collectionTimestamp'

            # Contains relationship fields
            targetLocation = 'targetLocation'
            targetSubscriptionId = 'targetSubscriptionId'
            targetDeviceId = 'targetDeviceId'
            sourceSubscriptionId = 'sourceSubscriptionId'

            # Key Vault access fields
            accessType = 'accessType'
            keyPermissions = 'keyPermissions'
            secretPermissions = 'secretPermissions'
            certificatePermissions = 'certificatePermissions'
            storagePermissions = 'storagePermissions'
            canGetSecrets = 'canGetSecrets'
            canListSecrets = 'canListSecrets'
            canSetSecrets = 'canSetSecrets'
            canGetKeys = 'canGetKeys'
            canDecryptWithKey = 'canDecryptWithKey'
            canGetCertificates = 'canGetCertificates'

            # Managed Identity fields
            identityType = 'identityType'
            userAssignedIdentityId = 'userAssignedIdentityId'
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'azureRelationshipsRawOut'
        ChangesOutBinding = 'azureRelationshipChangesOut'
    }
}
