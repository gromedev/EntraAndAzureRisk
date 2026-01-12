# Privileged Role Configuration
# Defines action patterns that indicate a role is security-sensitive

@{
    # Dangerous action patterns for Entra ID Directory Roles
    # These patterns indicate a role can perform security-sensitive operations
    DirectoryActionPatterns = @(
        'microsoft.directory/*/allTasks'                          # Full tenant admin
        'microsoft.directory/applications/credentials/*'           # App secret manipulation
        'microsoft.directory/servicePrincipals/credentials/*'      # SP secret manipulation
        'microsoft.directory/users/password/*'                     # Password resets
        'microsoft.directory/users/authenticationMethods/*'        # MFA bypass
        'microsoft.directory/roleAssignments/*'                    # Role assignment
        'microsoft.directory/roleDefinitions/*'                    # Role definition changes
        'microsoft.directory/conditionalAccessPolicies/*'          # CA policy changes
        'microsoft.directory/groups/members/*'                     # Group membership (could be role-assignable)
        'microsoft.directory/deviceManagementPolicies/*'           # Device policies
        'microsoft.directory/authorizationPolicy/*'                # Tenant authorization
        'microsoft.directory/entitlementManagement/*'              # Access packages
        'microsoft.directory/permissionGrantPolicies/*'            # Consent policies
    )

    # Dangerous action patterns for Azure RBAC Roles
    AzureActionPatterns = @(
        '*'                                                        # Full control (Owner)
        '*/write'                                                  # Write access to everything
        'Microsoft.Authorization/*'                                # RBAC manipulation
        'Microsoft.Authorization/roleAssignments/*'                # Role assignment
        'Microsoft.KeyVault/vaults/secrets/*'                      # Key Vault secrets
        'Microsoft.KeyVault/vaults/keys/*'                         # Key Vault keys
        'Microsoft.Compute/virtualMachines/*'                      # VM control
        'Microsoft.Compute/virtualMachineScaleSets/*'              # VMSS control
        'Microsoft.ContainerService/managedClusters/*'             # AKS control
        'Microsoft.Storage/storageAccounts/blobServices/containers/*' # Blob access
        'Microsoft.Web/sites/config/*'                             # App Service config (secrets)
        'Microsoft.Automation/automationAccounts/runbooks/*'       # Automation runbooks
        'Microsoft.ManagedIdentity/userAssignedIdentities/*'       # Managed identity control
    )

    # Known privileged directory role template IDs (for quick lookup in CollectRelationships)
    # These are the built-in roles that are always considered privileged
    PrivilegedDirectoryRoleTemplates = @(
        '62e90394-69f5-4237-9190-012177145e10'  # Global Administrator
        'e8611ab8-c189-46e8-94e1-60213ab1f814'  # Privileged Role Administrator
        '194ae4cb-b126-40b2-bd5b-6091b380977d'  # Security Administrator
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'  # SharePoint Administrator
        '29232cdf-9323-42fd-ade2-1d097af3e4de'  # Exchange Administrator
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'  # Application Administrator
        '158c047a-c907-4556-b7ef-446551a6b5f7'  # Cloud Application Administrator
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'  # Privileged Authentication Administrator
        '729827e3-9c14-49f7-bb1b-9608f156bbb8'  # Helpdesk Administrator
        'b0f54661-2d74-4c50-afa3-1ec803f12efe'  # Billing Administrator
        'fe930be7-5e62-47db-91af-98c3a49a38b1'  # User Administrator
        '9360feb5-f418-4baa-8175-e2a00bac4301'  # Directory Writers
        '966707d0-3269-4727-9be2-8c3a10f19b9d'  # Password Administrator
        'fdd7a751-b60b-444a-984c-02652fe8fa1c'  # Groups Administrator
        '11648597-926c-4cf3-9c36-bcebb0ba8dcc'  # Power Platform Administrator
        '44367163-eba1-44c3-98af-f5787879f96a'  # Dynamics 365 Administrator
        'd37c8bed-0711-4417-ba38-b4abe66ce4c2'  # Network Administrator
        '3a2c62db-5318-420d-8d74-23affee5d9d5'  # Intune Administrator
        '5f2222b1-57c3-48ba-8ad5-d4759f1fde6f'  # Security Operator
        '17315797-102d-40b4-93e0-432062caca18'  # Compliance Administrator
        'd29b2b05-8046-44ba-8758-1e26182fcf32'  # Directory Synchronization Accounts
        '2b745bdf-0803-4d80-aa65-822c4493daac'  # Office Apps Administrator
        '32696413-001a-46ae-978c-ce0f6b3620d2'  # Windows Update Deployment Administrator
        '31e939ad-9672-4796-9c2e-873181342d2d'  # Customer LockBox Access Approver
    )
}
