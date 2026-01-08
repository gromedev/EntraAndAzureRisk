# Dangerous Permissions Reference
# Maps Microsoft Graph permissions, Directory Roles, and Ownership patterns to abuse capabilities
# Used by DeriveEdges function to create derived attack edges

@{
    # ============================================
    # MICROSOFT GRAPH APPLICATION PERMISSIONS
    # Maps appRoleId (GUID) to abuse edge types
    # ============================================
    GraphPermissions = @{
        # ==========================================
        # CRITICAL - Full tenant compromise
        # ==========================================

        # Application.ReadWrite.All - Can add secrets to ANY application
        "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9" = @{
            Name = "Application.ReadWrite.All"
            AbuseEdge = "canAddSecretToAnyApp"
            Severity = "Critical"
            TargetType = "allApps"
            Description = "Can add credentials to any application registration"
        }

        # AppRoleAssignment.ReadWrite.All - Can grant ANY permission to ANY app
        "06b708a9-e830-4db3-a914-8e69da51d44f" = @{
            Name = "AppRoleAssignment.ReadWrite.All"
            AbuseEdge = "canGrantAnyPermission"
            Severity = "Critical"
            TargetType = "allApps"
            Description = "Can grant any app role to any service principal"
        }

        # RoleManagement.ReadWrite.Directory - Can assign ANY directory role
        "9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8" = @{
            Name = "RoleManagement.ReadWrite.Directory"
            AbuseEdge = "canAssignAnyRole"
            Severity = "Critical"
            TargetType = "allRoles"
            Description = "Can assign any directory role to any principal"
        }

        # Directory.ReadWrite.All - Broad directory modification
        "19dbc75e-c2e2-444c-a770-ec69d8559fc7" = @{
            Name = "Directory.ReadWrite.All"
            AbuseEdge = "canModifyDirectory"
            Severity = "Critical"
            TargetType = "directory"
            Description = "Can read and write all directory data"
        }

        # ServicePrincipalEndpoint.ReadWrite.All - Can modify SP endpoints
        "89c8469c-83ad-45f7-8ff2-6e3d4285709e" = @{
            Name = "ServicePrincipalEndpoint.ReadWrite.All"
            AbuseEdge = "canModifySpEndpoints"
            Severity = "Critical"
            TargetType = "allServicePrincipals"
            Description = "Can modify service principal endpoints"
        }

        # ==========================================
        # HIGH - Significant privilege escalation
        # ==========================================

        # Group.ReadWrite.All - Can modify ANY group
        "62a82d76-70ea-41e2-9197-370581804d09" = @{
            Name = "Group.ReadWrite.All"
            AbuseEdge = "canModifyAnyGroup"
            Severity = "High"
            TargetType = "allGroups"
            Description = "Can create/modify any group"
        }

        # GroupMember.ReadWrite.All - Can add members to ANY group
        "dbaae8cf-10b5-4b86-a4a1-f871c94c6695" = @{
            Name = "GroupMember.ReadWrite.All"
            AbuseEdge = "canAddMemberToAnyGroup"
            Severity = "High"
            TargetType = "allGroups"
            Description = "Can add/remove members from any group"
        }

        # User.ReadWrite.All - Can modify ANY user
        "741f803b-c850-494e-b5df-cde7c675a1ca" = @{
            Name = "User.ReadWrite.All"
            AbuseEdge = "canModifyAnyUser"
            Severity = "High"
            TargetType = "allUsers"
            Description = "Can modify any user's properties"
        }

        # User.ManageIdentities.All - Can manage user identities
        "c529cfca-c91b-489c-af2b-d92990571c75" = @{
            Name = "User.ManageIdentities.All"
            AbuseEdge = "canManageUserIdentities"
            Severity = "High"
            TargetType = "allUsers"
            Description = "Can manage federated identities for users"
        }

        # UserAuthenticationMethod.ReadWrite.All - Can reset ANY user's auth methods
        "50483e42-d915-4231-9639-7fdb7fd190e5" = @{
            Name = "UserAuthenticationMethod.ReadWrite.All"
            AbuseEdge = "canResetAnyAuthMethod"
            Severity = "High"
            TargetType = "allUsers"
            Description = "Can modify authentication methods for any user"
        }

        # Device.ReadWrite.All - Can modify any device
        "1138cb37-bd11-4084-a2b7-9f71582aeddb" = @{
            Name = "Device.ReadWrite.All"
            AbuseEdge = "canModifyAnyDevice"
            Severity = "High"
            TargetType = "allDevices"
            Description = "Can modify any device object"
        }

        # ==========================================
        # MEDIUM - Lateral movement / data access
        # ==========================================

        # Mail.ReadWrite - Can read/send mail as any user
        "e2a3a72e-5f79-4c64-b1b1-878b674786c9" = @{
            Name = "Mail.ReadWrite"
            AbuseEdge = "canAccessAnyMailbox"
            Severity = "Medium"
            TargetType = "allMailboxes"
            Description = "Can read and write mail in any mailbox"
        }

        # Mail.Send - Can send mail as any user
        "b633e1c5-b582-4048-a93e-9f11b44c7e96" = @{
            Name = "Mail.Send"
            AbuseEdge = "canSendMailAsAnyUser"
            Severity = "Medium"
            TargetType = "allUsers"
            Description = "Can send mail as any user"
        }

        # Files.ReadWrite.All - Can read/write ANY file in SharePoint/OneDrive
        "01d4889c-1287-42c6-ac1f-5d1e02578ef6" = @{
            Name = "Files.ReadWrite.All"
            AbuseEdge = "canAccessAllFiles"
            Severity = "Medium"
            TargetType = "allFiles"
            Description = "Can read and write all files"
        }

        # Sites.ReadWrite.All - Full SharePoint access
        "89fe6a52-be36-487e-b7d8-d061c450a026" = @{
            Name = "Sites.ReadWrite.All"
            AbuseEdge = "canAccessAllSites"
            Severity = "Medium"
            TargetType = "allSites"
            Description = "Can read and write all SharePoint sites"
        }

        # ==========================================
        # AZURE RESOURCE MANAGER PERMISSIONS
        # (For cross-cloud attack paths)
        # ==========================================

        # Note: Azure RBAC permissions are handled separately via azureRbac edges
        # These are included for completeness in Graph permission grants
    }

    # ============================================
    # DIRECTORY ROLES → IMPLICIT ABUSE CAPABILITIES
    # Maps roleTemplateId (GUID) to abuse edges
    # ============================================
    DirectoryRoles = @{
        # ==========================================
        # TIER 0 - CRITICAL PRIVILEGED ROLES
        # ==========================================

        # Global Administrator
        "62e90394-69f5-4237-9190-012177145e10" = @{
            Name = "Global Administrator"
            AbuseEdges = @("isGlobalAdmin", "canDoEverything")
            Severity = "Critical"
            Tier = 0
            Description = "Full control over all aspects of the tenant"
        }

        # Privileged Role Administrator
        "e8611ab8-c189-46e8-94e1-60213ab1f814" = @{
            Name = "Privileged Role Administrator"
            AbuseEdges = @("canAssignAnyRole", "canManagePIM")
            Severity = "Critical"
            Tier = 0
            Description = "Can assign any role including Global Administrator"
        }

        # Partner Tier2 Support
        "e00e864a-17c5-4a4b-9c06-f5b95a8d5bd8" = @{
            Name = "Partner Tier2 Support"
            AbuseEdges = @("isPartnerTier2", "canResetAllPasswords")
            Severity = "Critical"
            Tier = 0
            Description = "Partner support with broad access"
        }

        # ==========================================
        # TIER 0 - APPLICATION ADMINISTRATORS
        # Can add secrets = can become the app
        # ==========================================

        # Application Administrator
        "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3" = @{
            Name = "Application Administrator"
            AbuseEdges = @("canAddSecretToAnyApp", "canModifyAnyApp", "canConsentForAnyApp")
            Severity = "Critical"
            Tier = 0
            Description = "Full control over all application registrations and enterprise apps"
        }

        # Cloud Application Administrator
        "158c047a-c907-4556-b7ef-446551a6b5f7" = @{
            Name = "Cloud Application Administrator"
            AbuseEdges = @("canAddSecretToAnyApp", "canModifyAnyApp", "canConsentForAnyApp")
            Severity = "Critical"
            Tier = 0
            Description = "Full control over apps except AAD App Proxy"
        }

        # ==========================================
        # TIER 1 - HIGH PRIVILEGE ROLES
        # ==========================================

        # Privileged Authentication Administrator
        "7be44c8a-adaf-4e2a-84d6-ab2649e08a13" = @{
            Name = "Privileged Authentication Administrator"
            AbuseEdges = @("canResetAnyAuth", "canResetAnyPassword", "canResetAdminAuth")
            Severity = "Critical"
            Tier = 1
            Description = "Can reset auth for any user including Global Admins"
        }

        # User Administrator
        "fe930be7-5e62-47db-91af-98c3a49a38b1" = @{
            Name = "User Administrator"
            AbuseEdges = @("canModifyAnyUser", "canResetNonAdminPasswords", "canCreateUsers")
            Severity = "High"
            Tier = 1
            Description = "Can manage all aspects of users except privileged roles"
        }

        # Authentication Administrator
        "c4e39bd9-1100-46d3-8c65-fb160da0071f" = @{
            Name = "Authentication Administrator"
            AbuseEdges = @("canResetNonAdminAuth", "canResetMFA")
            Severity = "High"
            Tier = 1
            Description = "Can reset auth for non-admin users"
        }

        # Groups Administrator
        "fdd7a751-b60b-444a-984c-02652fe8fa1c" = @{
            Name = "Groups Administrator"
            AbuseEdges = @("canModifyAnyGroup", "canAddMemberToAnyGroup")
            Severity = "High"
            Tier = 1
            Description = "Can manage all groups including role-assignable groups"
        }

        # Intune Administrator
        "3a2c62db-5318-420d-8d74-23affee5d9d5" = @{
            Name = "Intune Administrator"
            AbuseEdges = @("canManageIntune", "canDeployToDevices")
            Severity = "High"
            Tier = 1
            Description = "Full access to Intune - can deploy scripts to devices"
        }

        # Exchange Administrator
        "29232cdf-9323-42fd-ade2-1d097af3e4de" = @{
            Name = "Exchange Administrator"
            AbuseEdges = @("canManageExchange", "canAccessAllMailboxes", "canCreateMailRules")
            Severity = "High"
            Tier = 1
            Description = "Full Exchange access including all mailboxes"
        }

        # SharePoint Administrator
        "f28a1f50-f6e7-4571-818b-6a12f2af6b6c" = @{
            Name = "SharePoint Administrator"
            AbuseEdges = @("canManageSharePoint", "canAccessAllSites")
            Severity = "High"
            Tier = 1
            Description = "Full SharePoint/OneDrive access"
        }

        # Teams Administrator
        "69091246-20e8-4a56-aa4d-066075b2a7a8" = @{
            Name = "Teams Administrator"
            AbuseEdges = @("canManageTeams")
            Severity = "High"
            Tier = 1
            Description = "Full Microsoft Teams management"
        }

        # Helpdesk Administrator
        "729827e3-9c14-49f7-bb1b-9608f156bbb8" = @{
            Name = "Helpdesk Administrator"
            AbuseEdges = @("canResetNonAdminPasswords")
            Severity = "Medium"
            Tier = 1
            Description = "Can reset passwords for non-admins"
        }

        # Password Administrator
        "966707d0-3269-4727-9be2-8c3a10f19b9d" = @{
            Name = "Password Administrator"
            AbuseEdges = @("canResetNonAdminPasswords")
            Severity = "Medium"
            Tier = 1
            Description = "Can reset passwords for non-admins"
        }

        # ==========================================
        # TIER 2 - CONDITIONAL ACCESS / SECURITY
        # ==========================================

        # Conditional Access Administrator
        "b1be1c3e-b65d-4f19-8427-f6fa0d97feb9" = @{
            Name = "Conditional Access Administrator"
            AbuseEdges = @("canModifyCAPolicies", "canBypassCA")
            Severity = "High"
            Tier = 2
            Description = "Can create/modify CA policies to bypass security"
        }

        # Security Administrator
        "194ae4cb-b126-40b2-bd5b-6091b380977d" = @{
            Name = "Security Administrator"
            AbuseEdges = @("canManageSecurity", "canModifyCAPolicies")
            Severity = "High"
            Tier = 2
            Description = "Broad security management including CA policies"
        }

        # Authentication Policy Administrator
        "0526716b-113d-4c15-b2c8-68e3c22b9f80" = @{
            Name = "Authentication Policy Administrator"
            AbuseEdges = @("canModifyAuthPolicies")
            Severity = "High"
            Tier = 2
            Description = "Can modify authentication strength and methods"
        }

        # ==========================================
        # TIER 2 - IDENTITY GOVERNANCE
        # ==========================================

        # Identity Governance Administrator
        "45d8d3c5-c802-45c6-b32a-1d70b5e1e86e" = @{
            Name = "Identity Governance Administrator"
            AbuseEdges = @("canManageAccessReviews", "canManageEntitlementManagement")
            Severity = "Medium"
            Tier = 2
            Description = "Can manage access reviews and entitlement"
        }

        # Privileged Access Administrator (duplicate of PRA but for Entra roles)
        # Note: This is actually "Privileged Identity Management Administrator"
        # Adding for completeness if the GUID differs

        # ==========================================
        # TIER 3 - DIRECTORY SYNC / HYBRID
        # ==========================================

        # Hybrid Identity Administrator
        "8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2" = @{
            Name = "Hybrid Identity Administrator"
            AbuseEdges = @("canManageHybridIdentity", "canModifyAADConnect")
            Severity = "High"
            Tier = 3
            Description = "Can manage AD Connect and hybrid features"
        }

        # Directory Synchronization Accounts
        "d29b2b05-8046-44ba-8758-1e26182fcf32" = @{
            Name = "Directory Synchronization Accounts"
            AbuseEdges = @("canSyncDirectory")
            Severity = "Medium"
            Tier = 3
            Description = "Service account for directory sync"
        }

        # ==========================================
        # TIER 3 - DEVICE MANAGEMENT
        # ==========================================

        # Cloud Device Administrator
        "7698a772-787b-4ac8-901f-60d6b08affd2" = @{
            Name = "Cloud Device Administrator"
            AbuseEdges = @("canManageCloudDevices", "canEnableDisableDevices")
            Severity = "Medium"
            Tier = 3
            Description = "Can manage cloud-joined devices"
        }

        # Windows 365 Administrator
        "11451d60-acb2-45eb-a7d6-43d0f0125c13" = @{
            Name = "Windows 365 Administrator"
            AbuseEdges = @("canManageCloudPCs")
            Severity = "Medium"
            Tier = 3
            Description = "Can manage Cloud PCs"
        }
    }

    # ============================================
    # OWNERSHIP → IMPLICIT ABUSE CAPABILITIES
    # App/SP owners can add secrets = impersonate
    # ============================================
    OwnershipAbuse = @{
        # Application ownership
        appOwner = @{
            AbuseEdge = "canAddSecret"
            TargetProperty = "targetId"
            Description = "Application owner can add secrets/certificates"
        }

        # Service Principal ownership
        spOwner = @{
            AbuseEdge = "canAddSecret"
            TargetProperty = "targetId"
            Description = "Service principal owner can add secrets/certificates"
        }

        # Group ownership (for role-assignable groups)
        groupOwner = @{
            AbuseEdge = "canModifyGroup"
            TargetProperty = "targetId"
            Description = "Group owner can modify group and add members"
            ConditionalAbuse = @{
                # Additional edge if target group is role-assignable
                IsRoleAssignable = @{
                    AbuseEdge = "canAssignRolesViaGroup"
                    Description = "Can assign directory roles via role-assignable group"
                }
            }
        }
    }

    # ============================================
    # AZURE RBAC → ENTRA ABUSE PATHS
    # Maps dangerous Azure roles to cross-cloud attacks
    # ============================================
    AzureRbacAbuse = @{
        # Owner - Full control including IAM
        "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" = @{
            Name = "Owner"
            AbuseEdge = "azureOwner"
            Severity = "Critical"
            Description = "Full control including assigning roles"
        }

        # Contributor - Can modify resources
        "b24988ac-6180-42a0-ab88-20f7382dd24c" = @{
            Name = "Contributor"
            AbuseEdge = "azureContributor"
            Severity = "High"
            Description = "Can modify resources but not IAM"
        }

        # User Access Administrator - Can assign roles
        "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9" = @{
            Name = "User Access Administrator"
            AbuseEdge = "canAssignAzureRoles"
            Severity = "Critical"
            Description = "Can assign any Azure RBAC role"
        }

        # Virtual Machine Contributor - Can run code on VMs
        "9980e02c-c2be-4d73-94e8-173b1dc7cf3c" = @{
            Name = "Virtual Machine Contributor"
            AbuseEdge = "canRunCodeOnVMs"
            Severity = "High"
            Description = "Can manage VMs including running commands"
        }

        # Key Vault Administrator - Full Key Vault access
        "00482a5a-887f-4fb3-b363-3b7fe8e74483" = @{
            Name = "Key Vault Administrator"
            AbuseEdge = "keyVaultAdmin"
            Severity = "High"
            Description = "Full Key Vault data plane access"
        }

        # Key Vault Secrets Officer - Can read/write secrets
        "b86a8fe4-44ce-4948-aee5-eccb2c155cd7" = @{
            Name = "Key Vault Secrets Officer"
            AbuseEdge = "canManageKeyVaultSecrets"
            Severity = "High"
            Description = "Can read and write Key Vault secrets"
        }

        # Automation Contributor - Can run runbooks
        "f353d9bd-d4a6-484e-a77a-8050b599b867" = @{
            Name = "Automation Contributor"
            AbuseEdge = "canRunRunbooks"
            Severity = "High"
            Description = "Can create/run automation runbooks"
        }

        # Logic App Contributor - Can modify logic apps
        "87a39d53-fc1b-424a-814c-f7e04687dc9e" = @{
            Name = "Logic App Contributor"
            AbuseEdge = "canModifyLogicApps"
            Severity = "Medium"
            Description = "Can modify Logic App workflows"
        }

        # Website Contributor - Can deploy web apps
        "de139f84-1756-47ae-9be6-808fbbe84772" = @{
            Name = "Website Contributor"
            AbuseEdge = "canDeployWebApps"
            Severity = "Medium"
            Description = "Can deploy to web apps and function apps"
        }
    }

    # ============================================
    # MICROSOFT GRAPH RESOURCE IDS
    # For filtering appRoleAssignments
    # ============================================
    WellKnownResourceIds = @{
        # Microsoft Graph
        MicrosoftGraph = "00000003-0000-0000-c000-000000000000"
        # Azure Active Directory Graph (legacy)
        AzureADGraph = "00000002-0000-0000-c000-000000000000"
        # Office 365 Management APIs
        Office365Management = "c5393580-f805-4401-95e8-94b7a6ef2fc2"
        # Windows Azure Service Management API
        AzureServiceManagement = "797f4846-ba00-4fd7-ba43-dac1f8f63013"
        # Azure Key Vault
        AzureKeyVault = "cfa8b339-82a2-471a-a3c9-0fc0be7a4093"
    }
}
