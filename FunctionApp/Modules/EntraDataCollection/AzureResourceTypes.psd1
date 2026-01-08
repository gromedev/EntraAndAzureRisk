@{
    # Azure Resource Types to collect
    # Each entry defines: Type (discriminator), Provider path, API version, and security-relevant fields to extract
    ResourceTypes = @(
        @{
            Type = "keyVault"
            Provider = "Microsoft.KeyVault/vaults"
            ApiVersion = "2023-07-01"
            SecurityFields = @("enableRbacAuthorization", "enableSoftDelete", "enablePurgeProtection", "publicNetworkAccess")
            HasAccessPolicies = $true
        }
        @{
            Type = "virtualMachine"
            Provider = "Microsoft.Compute/virtualMachines"
            ApiVersion = "2024-03-01"
            SecurityFields = @("identity")
            HasManagedIdentity = $true
        }
        @{
            Type = "storageAccount"
            Provider = "Microsoft.Storage/storageAccounts"
            ApiVersion = "2023-05-01"
            SecurityFields = @("allowBlobPublicAccess", "minimumTlsVersion", "supportsHttpsTrafficOnly", "publicNetworkAccess")
            Critical = $true  # allowBlobPublicAccess=true is critical risk
        }
        @{
            Type = "aksCluster"
            Provider = "Microsoft.ContainerService/managedClusters"
            ApiVersion = "2024-01-02-preview"
            SecurityFields = @("enablePrivateCluster", "disableLocalAccounts", "enableAzureRBAC", "aadProfile")
            HasManagedIdentity = $true
        }
        @{
            Type = "containerRegistry"
            Provider = "Microsoft.ContainerRegistry/registries"
            ApiVersion = "2023-11-01-preview"
            SecurityFields = @("adminUserEnabled", "publicNetworkAccess", "networkRuleSet")
            Critical = $true  # adminUserEnabled=true is security risk
        }
        @{
            Type = "vmScaleSet"
            Provider = "Microsoft.Compute/virtualMachineScaleSets"
            ApiVersion = "2024-03-01"
            SecurityFields = @("identity", "upgradePolicy", "automaticRepairsPolicy")
            HasManagedIdentity = $true
        }
        @{
            Type = "dataFactory"
            Provider = "Microsoft.DataFactory/factories"
            ApiVersion = "2018-06-01"
            SecurityFields = @("publicNetworkAccess", "encryption")
            HasManagedIdentity = $true
        }
        @{
            Type = "automationAccount"
            Provider = "Microsoft.Automation/automationAccounts"
            ApiVersion = "2023-11-01"
            SecurityFields = @("publicNetworkAccess", "encryption")
            HasManagedIdentity = $true
        }
        @{
            Type = "functionApp"
            Provider = "Microsoft.Web/sites"
            Filter = "kind eq 'functionapp'"
            ApiVersion = "2023-12-01"
            SecurityFields = @("identity", "httpsOnly", "clientCertEnabled")
            HasManagedIdentity = $true
        }
        @{
            Type = "logicApp"
            Provider = "Microsoft.Logic/workflows"
            ApiVersion = "2019-05-01"
            SecurityFields = @("identity", "accessControl")
            HasManagedIdentity = $true
        }
        @{
            Type = "webApp"
            Provider = "Microsoft.Web/sites"
            Filter = "kind eq 'app'"
            ApiVersion = "2023-12-01"
            SecurityFields = @("identity", "httpsOnly", "clientCertEnabled")
            HasManagedIdentity = $true
        }
    )
}
