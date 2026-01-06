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
}
