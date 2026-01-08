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

@description('Deploy Gremlin graph database (deferred to V3.6)')
param deployGremlin bool = false

@description('Tags to apply to all resources')
param tags object = {
  Environment: environment
  Workload: workloadName
  ManagedBy: 'Bicep'
  CostCenter: 'IT-Security'
  Project: 'EntraRiskAnalysis-V3.1'
  Version: '3.5'
}

// Generate unique suffix for globally unique names
var uniqueSuffix = uniqueString(resourceGroup().id)

// Resource names
var storageAccountName = take('st${workloadName}${environment}${uniqueSuffix}', 24)
var cosmosDbAccountName = 'cosno-${workloadName}-${environment}-${uniqueSuffix}'
var cosmosGremlinAccountName = 'cosgr-${workloadName}-${environment}-${uniqueSuffix}'  // V3.1: Gremlin for graph queries
var functionAppName = 'func-${workloadName}-data-${environment}-${uniqueSuffix}'
var appServicePlanName = 'asp-${workloadName}-${environment}-001'
var keyVaultName = take('keyvault${workloadName}${environment}${uniqueSuffix}', 24)
var appInsightsName = 'appi-${workloadName}-${environment}-001'
var logAnalyticsName = 'log-${workloadName}-${environment}-001'

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

// ===== V3 UNIFIED CONTAINERS (6 total) =====

// Container 1: principals (unified - users, groups, SPs, devices)
resource cosmosContainerPrincipals 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'principals'
  properties: {
    resource: {
      id: 'principals'
      partitionKey: {
        paths: ['/objectId']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/principalType/?' }
          { path: '/displayName/?' }
          { path: '/accountEnabled/?' }
          { path: '/userPrincipalName/?' }
          { path: '/deleted/?' }
          { path: '/effectiveFrom/?' }
          { path: '/effectiveTo/?' }
          { path: '/collectionTimestamp/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 2: resources (unified - applications, Azure resources)
resource cosmosContainerResources 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'resources'
  properties: {
    resource: {
      id: 'resources'
      partitionKey: {
        paths: ['/resourceType']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/resourceType/?' }
          { path: '/displayName/?' }
          { path: '/subscriptionId/?' }
          { path: '/deleted/?' }
          { path: '/effectiveFrom/?' }
          { path: '/effectiveTo/?' }
          { path: '/collectionTimestamp/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 3: edges (unified - all relationships)
resource cosmosContainerEdges 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'edges'
  properties: {
    resource: {
      id: 'edges'
      partitionKey: {
        paths: ['/edgeType']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/sourceId/?' }
          { path: '/targetId/?' }
          { path: '/edgeType/?' }
          { path: '/deleted/?' }
          { path: '/effectiveFrom/?' }
          { path: '/effectiveTo/?' }
          { path: '/collectionTimestamp/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 4: policies (unified - CA, role management, named locations)
resource cosmosContainerPolicies 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'policies'
  properties: {
    resource: {
      id: 'policies'
      partitionKey: {
        paths: ['/policyType']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/policyType/?' }
          { path: '/displayName/?' }
          { path: '/state/?' }
          { path: '/deleted/?' }
          { path: '/effectiveFrom/?' }
          { path: '/effectiveTo/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 5: events (unified - sign-ins, audits, with TTL)
resource cosmosContainerEvents 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'events'
  properties: {
    resource: {
      id: 'events'
      partitionKey: {
        paths: ['/eventDate']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/eventType/?' }
          { path: '/eventDate/?' }
          { path: '/userId/?' }
          { path: '/createdDateTime/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: 7776000  // 90 days TTL
    }
  }
}

// Container 6: audit (unified audit trail - NO TTL, permanent history)
resource cosmosContainerAudit 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'audit'
  properties: {
    resource: {
      id: 'audit'
      partitionKey: {
        paths: ['/auditDate']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/auditDate/?' }
          { path: '/changeType/?' }
          { path: '/entityType/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: -1  // Keep forever - complete audit trail
    }
  }
}

// ===== V3.6 GREMLIN DATABASE (Separate account for graph queries) =====
// Note: Gremlin deployment is deferred to V3.6. Set deployGremlin=true to enable.

resource cosmosGremlinAccount 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = if (deployGremlin) {
  name: cosmosGremlinAccountName
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
    capabilities: [
      {
        name: 'EnableGremlin'  // Enable Gremlin API
      }
    ]
    enableFreeTier: false
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource cosmosGremlinDatabase 'Microsoft.DocumentDB/databaseAccounts/gremlinDatabases@2023-04-15' = if (deployGremlin) {
  parent: cosmosGremlinAccount
  name: 'EntraGraph'
  properties: {
    resource: {
      id: 'EntraGraph'
    }
  }
}

resource cosmosGremlinGraph 'Microsoft.DocumentDB/databaseAccounts/gremlinDatabases/graphs@2023-04-15' = if (deployGremlin) {
  parent: cosmosGremlinDatabase
  name: 'graph'
  properties: {
    resource: {
      id: 'graph'
      partitionKey: {
        paths: ['/pk']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/*' }
        ]
        excludedPaths: [
          { path: '/"_etag"/?' }
        ]
      }
    }
  }
}

// Gremlin RBAC: Grant Function App access to Gremlin account
resource cosmosGremlinDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = if (deployGremlin) {
  parent: cosmosGremlinAccount
  name: guid(cosmosGremlinAccount.id, functionApp.id, 'gremlin-data-contributor')
  properties: {
    // Built-in Cosmos DB Data Contributor role
    roleDefinitionId: '${cosmosGremlinAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: functionApp.identity.principalId
    scope: cosmosGremlinAccount.id
  }
}

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
        // V3 Unified Cosmos Container Names
        {
          name: 'COSMOS_CONTAINER_PRINCIPALS'
          value: cosmosContainerPrincipals.name
        }
        {
          name: 'COSMOS_CONTAINER_RESOURCES'
          value: cosmosContainerResources.name
        }
        {
          name: 'COSMOS_CONTAINER_EDGES'
          value: cosmosContainerEdges.name
        }
        {
          name: 'COSMOS_CONTAINER_POLICIES'
          value: cosmosContainerPolicies.name
        }
        {
          name: 'COSMOS_CONTAINER_EVENTS'
          value: cosmosContainerEvents.name
        }
        {
          name: 'COSMOS_CONTAINER_AUDIT'
          value: cosmosContainerAudit.name
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
        // PIM Configuration
        {
          name: 'ROLE_CACHE_DURATION_MINUTES'
          value: '5'
        }
        {
          name: 'PIM_PARALLEL_THROTTLE'
          value: '10'
        }
        // V3.6 Gremlin Configuration - Add these when deployGremlin=true
        // {
        //   name: 'COSMOS_GREMLIN_ENDPOINT'
        //   value: 'wss://${cosmosGremlinAccount.name}.gremlin.cosmos.azure.com:443/'
        // }
        // {
        //   name: 'COSMOS_GREMLIN_DATABASE'
        //   value: cosmosGremlinDatabase.name
        // }
        // {
        //   name: 'COSMOS_GREMLIN_CONTAINER'
        //   value: cosmosGremlinGraph.name
        // }
        // {
        //   name: 'COSMOS_GREMLIN_KEY'
        //   value: cosmosGremlinAccount.listKeys().primaryMasterKey
        // }
      ]
    }
  }
}

// AI Foundry removed in V3 - TestAIFoundry feature deleted

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

// AI Foundry role assignments removed in V3

// OUTPUTS

output storageAccountName string = storageAccount.name
output functionAppName string = functionApp.name
output cosmosDbAccountName string = cosmosDbAccount.name
output cosmosDbEndpoint string = cosmosDbAccount.properties.documentEndpoint
output cosmosDatabaseName string = cosmosDatabase.name
// V3 Unified Container Outputs
output cosmosContainerPrincipals string = cosmosContainerPrincipals.name
output cosmosContainerResources string = cosmosContainerResources.name
output cosmosContainerEdges string = cosmosContainerEdges.name
output cosmosContainerPolicies string = cosmosContainerPolicies.name
output cosmosContainerEvents string = cosmosContainerEvents.name
output cosmosContainerAudit string = cosmosContainerAudit.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
output functionAppIdentityPrincipalId string = functionApp.identity.principalId
output blobRetentionDays int = blobRetentionDays
// V3.6 Gremlin Outputs (only when deployGremlin=true)
output cosmosGremlinAccountName string = deployGremlin ? cosmosGremlinAccount.name : 'not-deployed'
output cosmosGremlinEndpoint string = deployGremlin ? 'wss://${cosmosGremlinAccount.name}.gremlin.cosmos.azure.com:443/' : 'not-deployed'
output cosmosGremlinDatabase string = deployGremlin ? cosmosGremlinDatabase.name : 'not-deployed'
output cosmosGremlinGraph string = deployGremlin ? cosmosGremlinGraph.name : 'not-deployed'
