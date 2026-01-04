@description('The workload name used for naming resources')
param workloadName string = 'entrarisk'

@description('The environment name (dev, test, prod)')
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string = 'dev'

@description('The Azure region for resources')
param location string = resourceGroup().location

@description('Entra ID Tenant ID for authentication')
param tenantId string

@description('Blob retention days (7 for pilot, 30 for production)')
param blobRetentionDays int = 7

@description('Tags to apply to all resources')
param tags object = {
  Environment: environment
  Workload: workloadName
  ManagedBy: 'Bicep'
  CostCenter: 'IT-Security'
  Project: 'EntraRiskAnalysis-Delta'
  Version: '2.0-Delta'
}

// Generate unique suffix for globally unique names
var uniqueSuffix = uniqueString(resourceGroup().id)

// Resource names
var storageAccountName = take('st${workloadName}${environment}${uniqueSuffix}', 24)
var cosmosDbAccountName = 'cosno-${workloadName}-${environment}-${uniqueSuffix}'
var functionAppName = 'func-${workloadName}-data-${environment}-${uniqueSuffix}'
var appServicePlanName = 'asp-${workloadName}-${environment}-001'
var keyVaultName = take('keyvault${workloadName}${environment}${uniqueSuffix}', 24)
var appInsightsName = 'appi-${workloadName}-${environment}-001'
var logAnalyticsName = 'log-${workloadName}-${environment}-001'
var aiFoundryHubName = 'hub-${workloadName}-${environment}-${uniqueSuffix}'
var aiFoundryProjectName = 'proj-${workloadName}-${environment}-${uniqueSuffix}'

// STORAGE ACCOUNT WITH LIFECYCLE MANAGEMENT

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource rawDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'raw-data'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'Landing zone for Graph API exports'
      retention: '${blobRetentionDays} days'
    }
  }
}

resource analysisContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'analysis'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle policy to auto-delete old blobs
resource blobLifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'tier-and-delete-raw-data'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['raw-data/']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 7  // Move to cool tier after 7 days
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 30  // Move to archive after 30 days
                }
                delete: {
                  daysAfterModificationGreaterThan: 90  // Delete after 90 days (data is in Cosmos DB)
                }
              }
            }
          }
        }
      ]
    }
  }
}

// COSMOS DB - THREE CONTAINERS

resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosDbAccountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: false
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [] 
    enableFreeTier: false 
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-04-15' = {
  parent: cosmosDbAccount
  name: 'EntraData'
  properties: {
    resource: {
      id: 'EntraData'
    }
  }
}

// Container 1: Current state of all users
resource cosmosContainerUsersRaw 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'users_raw'
  properties: {
    resource: {
      id: 'users_raw'
      partitionKey: {
        paths: ['/objectId']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/userPrincipalName/?' }
          { path: '/accountEnabled/?' }
          { path: '/userType/?' }
          { path: '/lastSignInDateTime/?' }
          { path: '/collectionTimestamp/?' }
          { path: '/lastModified/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      uniqueKeyPolicy: {
        uniqueKeys: [
          {
            paths: ['/objectId']
          }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 2: Change log (audit trail)
resource cosmosContainerUserChanges 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'user_changes'
  properties: {
    resource: {
      id: 'user_changes'
      partitionKey: {
        paths: ['/snapshotId']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/changeType/?' }
          { path: '/changeTimestamp/?' }
          { path: '/snapshotId/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1  // Keep forever - complete audit trail
    }
  }
}

// Container 3: Collection metadata and summaries
resource cosmosContainerSnapshots 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'snapshots'
  properties: {
    resource: {
      id: 'snapshots'
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
      }
      defaultTtl: -1
    }
  }
}

// NOTE: groups_raw and group_changes containers already exist
// They were created manually and have TTL configured via Azure CLI
// Container 4: groups_raw - Current state with soft delete support (defaultTtl: -1)
// Container 5: group_changes - Audit trail (defaultTtl: -1)

// COSMOS DB AUDIT PROTECTION

// Diagnostic settings - Log ALL Cosmos DB operations to Log Analytics
resource cosmosDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'cosmos-audit-logs'
  scope: cosmosDbAccount
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'DataPlaneRequests'  // All read/write/delete operations
        enabled: true
      }
      {
        category: 'QueryRuntimeStatistics'
        enabled: true
      }
      {
        category: 'PartitionKeyStatistics'
        enabled: true
      }
      {
        category: 'ControlPlaneRequests'  // Admin operations (container create/delete)
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Requests'
        enabled: true
      }
    ]
  }
}

// Custom Cosmos DB RBAC Role: Can write but CANNOT delete from *_changes containers
resource cosmosAuditWriterRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2023-04-15' = {
  parent: cosmosDbAccount
  name: guid(cosmosDbAccount.id, 'audit-writer-role')
  properties: {
    roleName: 'Audit Trail Writer (No Delete)'
    type: 'CustomRole'
    assignableScopes: [
      cosmosDbAccount.id
    ]
    permissions: [
      {
        dataActions: [
          // Read permissions (for delta detection)
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery'

          // Write permissions (create/upsert/replace)
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/upsert'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'

          // NOTE: NO delete permission - cannot delete audit trail records
        ]
      }
    ]
  }
}

// Assign Function App to the custom role
resource functionAppCosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosDbAccount
  name: guid(cosmosDbAccount.id, functionApp.id, 'audit-writer-assignment')
  properties: {
    roleDefinitionId: cosmosAuditWriterRole.id
    principalId: functionApp.identity.principalId
    scope: cosmosDbAccount.id
  }
}

// KEY VAULT, MONITORING, FUNCTION APP (Same as before)

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForTemplateDeployment: true
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${az.environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${az.environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name: 'COSMOS_DB_ENDPOINT'
          value: cosmosDbAccount.properties.documentEndpoint
        }
        {
          name: 'COSMOS_DB_DATABASE'
          value: cosmosDatabase.name
        }
        {
          name: 'COSMOS_CONTAINER_USERS_RAW'
          value: cosmosContainerUsersRaw.name
        }
        {
          name: 'COSMOS_CONTAINER_USER_CHANGES'
          value: cosmosContainerUserChanges.name
        }
        {
          name: 'COSMOS_CONTAINER_SNAPSHOTS'
          value: cosmosContainerSnapshots.name
        }
        {
          name: 'CosmosDbConnectionString'
          value: cosmosDbAccount.listConnectionStrings().connectionStrings[0].connectionString
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'TENANT_ID'
          value: tenantId
        }
        {
          name: 'AI_FOUNDRY_ENDPOINT'
          value: aiFoundryHub.properties.discoveryUrl
        }
        {
          name: 'AI_FOUNDRY_PROJECT_NAME'
          value: aiFoundryProjectName
        }
        {
          name: 'AI_MODEL_DEPLOYMENT_NAME'
          value: 'gpt-4o-mini'
        }
        // Collection Configuration
        {
          name: 'BATCH_SIZE'
          value: '999'
        }
        {
          name: 'PARALLEL_THROTTLE'
          value: '10'
        }
        // Cosmos DB Configuration
        {
          name: 'COSMOS_BATCH_SIZE'
          value: '100'
        }
        {
          name: 'ENABLE_DELTA_DETECTION'
          value: 'true'
        }
        // Blob Retention
        {
          name: 'BLOB_RETENTION_DAYS'
          value: string(blobRetentionDays)
        }
      ]
    }
  }
}

resource aiFoundryHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: aiFoundryHubName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'Hub'
  properties: {
    friendlyName: 'Entra Risk Analysis AI Hub - Delta'
    description: 'AI Foundry Hub with delta change detection'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
  }
}

resource aiFoundryProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: aiFoundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'Project'
  properties: {
    friendlyName: 'Entra Risk Analysis Project - Delta'
    description: 'AI project with change tracking'
    hubResourceId: aiFoundryHub.id
  }
}

// RBAC ASSIGNMENTS

resource functionAppStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// OLD ROLE REMOVED: Was using built-in Cosmos DB Data Contributor (allows delete)
// NOW USING: Custom "Audit Trail Writer (No Delete)" role defined above

resource functionAppKeyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionAppAiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundryHub.id, functionApp.id, '64702f94-c441-49e6-a78b-ef80e0188fee')
  scope: aiFoundryHub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '64702f94-c441-49e6-a78b-ef80e0188fee') // Azure AI Developer
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aiFoundryCosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosDbAccount
  name: guid(aiFoundryHub.id, cosmosDbAccount.id, '00000000-0000-0000-0000-000000000001')
  properties: {
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001'
    principalId: aiFoundryHub.identity.principalId
    scope: cosmosDbAccount.id
  }
}

resource aiFoundryStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aiFoundryHub.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: aiFoundryHub.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// OUTPUTS

output storageAccountName string = storageAccount.name
output functionAppName string = functionApp.name
output cosmosDbAccountName string = cosmosDbAccount.name
output cosmosDbEndpoint string = cosmosDbAccount.properties.documentEndpoint
output cosmosDatabaseName string = cosmosDatabase.name
output cosmosContainerUsersRaw string = cosmosContainerUsersRaw.name
output cosmosContainerUserChanges string = cosmosContainerUserChanges.name
output cosmosContainerSnapshots string = cosmosContainerSnapshots.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
output functionAppIdentityPrincipalId string = functionApp.identity.principalId
output blobRetentionDays int = blobRetentionDays
