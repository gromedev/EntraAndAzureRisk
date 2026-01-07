# Centralized Indexer Configurations
# Each entity type has its own configuration for delta indexing
# Used by Invoke-DeltaIndexingWithBindings to reduce code duplication in indexers

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
            'deleted'
        )
        ArrayFields = @()
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
            'deleted'
        )
        ArrayFields = @('passwordCredentials', 'keyCredentials')
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
        CompareFields = @(
            # Common fields (all principal types)
            'principalType'
            'displayName'
            'accountEnabled'
            'deleted'

            # User-specific fields (null for non-users)
            'userPrincipalName'
            'userType'
            'mail'
            'jobTitle'
            'department'
            'companyName'
            'lastSignInDateTime'
            'lastNonInteractiveSignInDateTime'
            'passwordPolicies'
            'usageLocation'
            'externalUserState'
            'externalUserStateChangeDateTime'
            'onPremisesSyncEnabled'
            'onPremisesSamAccountName'
            'onPremisesUserPrincipalName'
            'onPremisesSecurityIdentifier'
            'managerId'
            'managerDisplayName'
            'risk'
            'authMethods'

            # Group-specific fields (null for non-groups)
            'securityEnabled'
            'mailEnabled'
            'groupTypes'
            'membershipRule'
            'membershipRuleProcessingState'
            'isAssignableToRole'
            'visibility'
            'classification'
            'memberCountDirect'
            'memberCountTransitive'

            # ServicePrincipal-specific fields (null for non-SPs)
            'appId'
            'appDisplayName'
            'servicePrincipalType'
            'appRoleAssignmentRequired'
            'appOwnerOrganizationId'
            'servicePrincipalNames'
            'tags'
            'spCredentials'

            # Application-specific fields (null for non-apps)
            'signInAudience'
            'publisherDomain'
            'verifiedPublisher'
            'credentials'

            # Device-specific fields (null for non-devices)
            'deviceId'
            'operatingSystem'
            'operatingSystemVersion'
            'isCompliant'
            'isManaged'
            'trustType'
            'profileType'
            'manufacturer'
            'model'
            'approximateLastSignInDateTime'
            'registrationDateTime'
        )
        ArrayFields = @(
            'groupTypes'
            'servicePrincipalNames'
            'tags'
        )
        EmbeddedObjectFields = @(
            'risk'
            'authMethods'
            'spCredentials'
            'credentials'
            'verifiedPublisher'
        )
        DocumentFields = @{
            # Common fields
            principalType = 'principalType'
            displayName = 'displayName'
            accountEnabled = 'accountEnabled'
            createdDateTime = 'createdDateTime'
            deletedDateTime = 'deletedDateTime'
            collectionTimestamp = 'collectionTimestamp'

            # User fields
            userPrincipalName = 'userPrincipalName'
            userType = 'userType'
            mail = 'mail'
            mailNickname = 'mailNickname'
            givenName = 'givenName'
            surname = 'surname'
            jobTitle = 'jobTitle'
            department = 'department'
            companyName = 'companyName'
            officeLocation = 'officeLocation'
            city = 'city'
            state = 'state'
            country = 'country'
            usageLocation = 'usageLocation'
            preferredLanguage = 'preferredLanguage'
            lastSignInDateTime = 'lastSignInDateTime'
            lastNonInteractiveSignInDateTime = 'lastNonInteractiveSignInDateTime'
            passwordPolicies = 'passwordPolicies'
            externalUserState = 'externalUserState'
            externalUserStateChangeDateTime = 'externalUserStateChangeDateTime'
            onPremisesSyncEnabled = 'onPremisesSyncEnabled'
            onPremisesSamAccountName = 'onPremisesSamAccountName'
            onPremisesUserPrincipalName = 'onPremisesUserPrincipalName'
            onPremisesSecurityIdentifier = 'onPremisesSecurityIdentifier'
            onPremisesLastSyncDateTime = 'onPremisesLastSyncDateTime'
            managerId = 'managerId'
            managerDisplayName = 'managerDisplayName'
            managerUserPrincipalName = 'managerUserPrincipalName'
            risk = 'risk'
            authMethods = 'authMethods'

            # Group fields
            description = 'description'
            securityEnabled = 'securityEnabled'
            mailEnabled = 'mailEnabled'
            groupTypes = 'groupTypes'
            membershipRule = 'membershipRule'
            membershipRuleProcessingState = 'membershipRuleProcessingState'
            isAssignableToRole = 'isAssignableToRole'
            visibility = 'visibility'
            classification = 'classification'
            resourceProvisioningOptions = 'resourceProvisioningOptions'
            memberCountDirect = 'memberCountDirect'
            memberCountTransitive = 'memberCountTransitive'

            # ServicePrincipal fields
            appId = 'appId'
            appDisplayName = 'appDisplayName'
            servicePrincipalType = 'servicePrincipalType'
            appRoleAssignmentRequired = 'appRoleAssignmentRequired'
            appOwnerOrganizationId = 'appOwnerOrganizationId'
            homepage = 'homepage'
            loginUrl = 'loginUrl'
            logoutUrl = 'logoutUrl'
            replyUrls = 'replyUrls'
            servicePrincipalNames = 'servicePrincipalNames'
            tags = 'tags'
            notificationEmailAddresses = 'notificationEmailAddresses'
            oauth2PermissionScopes = 'oauth2PermissionScopes'
            appRoles = 'appRoles'
            spCredentials = 'spCredentials'

            # Application fields
            signInAudience = 'signInAudience'
            publisherDomain = 'publisherDomain'
            verifiedPublisher = 'verifiedPublisher'
            credentials = 'credentials'

            # Device fields
            deviceId = 'deviceId'
            operatingSystem = 'operatingSystem'
            operatingSystemVersion = 'operatingSystemVersion'
            isCompliant = 'isCompliant'
            isManaged = 'isManaged'
            isRooted = 'isRooted'
            managementType = 'managementType'
            trustType = 'trustType'
            profileType = 'profileType'
            manufacturer = 'manufacturer'
            model = 'model'
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
        }
        WriteDeletes = $true
        IncludeDeleteMarkers = $true
        RawOutBinding = 'relationshipsRawOut'
        ChangesOutBinding = 'relationshipChangesOut'
    }

    # ============================================
    # POLICIES (Unified: CA policies, role policies)
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
        )
        ArrayFields = @(
            'conditions'
            'grantControls'
            'sessionControls'
            'rules'
            'effectiveRules'
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
}
