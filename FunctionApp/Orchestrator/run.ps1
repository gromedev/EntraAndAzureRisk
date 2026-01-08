
#region Durable Functions Orchestrator - V3.5 CONSOLIDATED ARCHITECTURE
<#
.SYNOPSIS
    Orchestrates comprehensive Entra and Azure data collection with unified containers
.DESCRIPTION
    V3.5 Architecture: Consolidated Collectors with Unified Containers

    6 Cosmos DB Containers:
    - principals (users, groups, servicePrincipals, devices) - partition: /principalType
    - resources (applications, Azure resources, role definitions) - partition: /resourceType
    - edges (all relationships unified + derived abuse/virtual edges) - partition: /edgeType
    - policies (CA + Intune policies) - partition: /policyType
    - events - partition: /eventDate
    - audit (changes + snapshots) - partition: /auditDate

    Phase 1: Entity Collection (Parallel - 12 collectors)
      Principal Collectors (4):
      - CollectUsers -> principals.jsonl (principalType=user, with embedded auth methods + risk data)
      - CollectEntraGroups -> principals.jsonl (principalType=group)
      - CollectEntraServicePrincipals -> principals.jsonl (principalType=servicePrincipal)
      - CollectDevices -> principals.jsonl (principalType=device)

      Resource Collectors (4):
      - CollectAppRegistrations -> resources.jsonl (resourceType=application)
      - CollectAzureHierarchy -> resources.jsonl (resourceType=tenant/managementGroup/subscription/resourceGroup)
      - CollectAzureResources -> resources.jsonl (CONSOLIDATED: keyVault, virtualMachine, storageAccount, etc.)
      - CollectRoleDefinitions -> resources.jsonl (CONSOLIDATED: directoryRoleDefinition, azureRoleDefinition)

      Policy/Event Collectors (3):
      - CollectPolicies -> policies.jsonl (CA policies)
      - CollectIntunePolicies -> policies.jsonl (compliance + app protection policies)
      - CollectEvents -> events.jsonl

    Phase 2: Unified Edge Collection
      - CollectRelationships -> edges.jsonl (all 24+ edgeTypes)

    Phase 3: Unified Indexing (5 indexers)
      - IndexPrincipalsInCosmosDB -> principals container
      - IndexResourcesInCosmosDB -> resources container
      - IndexEdgesInCosmosDB -> edges container
      - IndexPoliciesInCosmosDB -> policies container
      - IndexEventsInCosmosDB -> events container

    Phase 4: Derive Edges (2 derivation functions)
      - DeriveAbuseEdges -> edges container (attack path capabilities)
      - DeriveVirtualEdges -> edges container (policy gate edges)

    V3.5 Benefits:
    - Consolidated collectors: 17 -> 12 collectors
    - Configuration-driven Azure resource collection (AzureResourceTypes.psd1)
    - Embedded risk data in users (no separate risky users collection)
    - Derived virtual edges for Intune policy coverage analysis
    - Semantic correctness (applications are resources, not principals)
    - Unified edge container enables Gremlin graph projection
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration (V3.5 - Consolidated Architecture)"
    Write-Verbose "Instance ID: $($Context.InstanceId)"

    # Single Get-Date call to prevent race condition
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Verbose "Collection timestamp: $timestampFormatted"

    $collectionInput = @{
        Timestamp = $timestamp
    }

    #region Phase 1: Entity Collection (Parallel - 12 collectors)
    Write-Verbose "Phase 1: Collecting all entities in parallel (12 collectors)..."

    # Principal Collectors (4) - output to principals.jsonl
    $usersTask = Invoke-DurableActivity `
        -FunctionName 'CollectUsers' `
        -Input $collectionInput `
        -NoWait

    $groupsTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraGroups' `
        -Input $collectionInput `
        -NoWait

    $servicePrincipalsTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraServicePrincipals' `
        -Input $collectionInput `
        -NoWait

    $devicesTask = Invoke-DurableActivity `
        -FunctionName 'CollectDevices' `
        -Input $collectionInput `
        -NoWait

    # Resource Collectors (4) - output to resources.jsonl
    $applicationsTask = Invoke-DurableActivity `
        -FunctionName 'CollectAppRegistrations' `
        -Input $collectionInput `
        -NoWait

    $azureHierarchyTask = Invoke-DurableActivity `
        -FunctionName 'CollectAzureHierarchy' `
        -Input $collectionInput `
        -NoWait

    # V3.5 CONSOLIDATED: Azure Resources (keyVault, virtualMachine, storageAccount, etc.)
    $azureResourcesTask = Invoke-DurableActivity `
        -FunctionName 'CollectAzureResources' `
        -Input $collectionInput `
        -NoWait

    # V3.5 CONSOLIDATED: Role Definitions (directory + Azure)
    $roleDefinitionsTask = Invoke-DurableActivity `
        -FunctionName 'CollectRoleDefinitions' `
        -Input $collectionInput `
        -NoWait

    # Policy Collectors (2) - output to policies.jsonl
    $policiesTask = Invoke-DurableActivity `
        -FunctionName 'CollectPolicies' `
        -Input $collectionInput `
        -NoWait

    # V3.5: Consolidated Intune Policies (compliance + app protection)
    $intunePoliciesTask = Invoke-DurableActivity `
        -FunctionName 'CollectIntunePolicies' `
        -Input $collectionInput `
        -NoWait

    # Event Collector
    $eventsTask = Invoke-DurableActivity `
        -FunctionName 'CollectEvents' `
        -Input $collectionInput `
        -NoWait
    #endregion

    #region Phase 2: Unified Edge Collection
    Write-Verbose "Phase 2: Collecting all relationships (unified edges)..."

    $edgesTask = Invoke-DurableActivity `
        -FunctionName 'CollectRelationships' `
        -Input $collectionInput `
        -NoWait
    #endregion

    #region Wait for All Collections
    Write-Verbose "Waiting for all 12 collectors to complete..."

    $allResults = Wait-ActivityFunction -Task @(
        $usersTask,
        $groupsTask,
        $servicePrincipalsTask,
        $devicesTask,
        $applicationsTask,
        $azureHierarchyTask,
        $azureResourcesTask,
        $roleDefinitionsTask,
        $policiesTask,
        $intunePoliciesTask,
        $eventsTask,
        $edgesTask
    )

    # Unpack results (12 collectors)
    $usersResult = $allResults[0]
    $groupsResult = $allResults[1]
    $servicePrincipalsResult = $allResults[2]
    $devicesResult = $allResults[3]
    $applicationsResult = $allResults[4]
    $azureHierarchyResult = $allResults[5]
    $azureResourcesResult = $allResults[6]
    $roleDefinitionsResult = $allResults[7]
    $policiesResult = $allResults[8]
    $intunePoliciesResult = $allResults[9]
    $eventsResult = $allResults[10]
    $edgesResult = $allResults[11]
    #endregion

    #region Validate Collection Results
    # Users is critical - fail fast if it fails
    if (-not $usersResult.Success) {
        throw "User collection failed (critical): $($usersResult.Error)"
    }

    # Other principal collections are important but non-critical
    if (-not $groupsResult.Success) {
        Write-Warning "Groups collection failed: $($groupsResult.Error)"
        $groupsResult = @{ Success = $false; GroupCount = 0; PrincipalsBlobName = $null }
    }

    if (-not $servicePrincipalsResult.Success) {
        Write-Warning "Service Principals collection failed: $($servicePrincipalsResult.Error)"
        $servicePrincipalsResult = @{ Success = $false; ServicePrincipalCount = 0; PrincipalsBlobName = $null }
    }

    if (-not $devicesResult.Success) {
        Write-Warning "Devices collection failed: $($devicesResult.Error)"
        $devicesResult = @{ Success = $false; DeviceCount = 0; PrincipalsBlobName = $null }
    }

    # Resource collections are non-critical
    if (-not $applicationsResult.Success) {
        Write-Warning "Applications collection failed: $($applicationsResult.Error)"
        $applicationsResult = @{ Success = $false; AppCount = 0; ResourcesBlobName = $null }
    }

    # Azure collectors are non-critical (may not have ARM permissions)
    if (-not $azureHierarchyResult.Success) {
        Write-Warning "Azure hierarchy collection failed: $($azureHierarchyResult.Error)"
        $azureHierarchyResult = @{ Success = $false; ResourceCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    # V3.5 CONSOLIDATED: Azure Resources (replaces individual collectors)
    if (-not $azureResourcesResult.Success) {
        Write-Warning "Azure Resources collection failed: $($azureResourcesResult.Error)"
        $azureResourcesResult = @{ Success = $false; ResourceCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null; Statistics = @{} }
    }

    # V3.5 CONSOLIDATED: Role Definitions
    if (-not $roleDefinitionsResult.Success) {
        Write-Warning "Role Definitions collection failed: $($roleDefinitionsResult.Error)"
        $roleDefinitionsResult = @{ Success = $false; RoleDefinitionCount = 0; ResourcesBlobName = $null; Statistics = @{} }
    }

    if (-not $policiesResult.Success) {
        Write-Warning "Policies collection failed: $($policiesResult.Error)"
        $policiesResult = @{ Success = $false; PolicyCount = 0; BlobName = $null }
    }

    # V3.5: Intune Policies (non-critical - requires Intune license)
    if (-not $intunePoliciesResult.Success) {
        Write-Warning "Intune Policies collection failed: $($intunePoliciesResult.Error)"
        $intunePoliciesResult = @{ Success = $false; PolicyCount = 0; BlobName = $null; Statistics = @{} }
    }

    if (-not $eventsResult.Success) {
        Write-Warning "Events collection failed: $($eventsResult.Error)"
        $eventsResult = @{ Success = $false; EventCount = 0; BlobName = $null }
    }

    if (-not $edgesResult.Success) {
        Write-Warning "Edges collection failed: $($edgesResult.Error)"
        $edgesResult = @{ Success = $false; EdgeCount = 0; EdgesBlobName = $null }
    }

    Write-Verbose "Collection complete:"
    Write-Verbose "  Users: $($usersResult.UserCount ?? 0) (risk data embedded)"
    Write-Verbose "  Groups: $($groupsResult.GroupCount ?? 0)"
    Write-Verbose "  Service Principals: $($servicePrincipalsResult.ServicePrincipalCount ?? 0)"
    Write-Verbose "  Devices: $($devicesResult.DeviceCount ?? 0)"
    Write-Verbose "  Applications: $($applicationsResult.AppCount ?? 0)"
    Write-Verbose "  Azure Hierarchy: $($azureHierarchyResult.ResourceCount ?? 0)"
    Write-Verbose "  Azure Resources: $($azureResourcesResult.ResourceCount ?? 0) (consolidated)"
    Write-Verbose "  Role Definitions: $($roleDefinitionsResult.RoleDefinitionCount ?? 0) (consolidated)"
    Write-Verbose "  CA Policies: $($policiesResult.PolicyCount ?? 0)"
    Write-Verbose "  Intune Policies: $($intunePoliciesResult.PolicyCount ?? 0)"
    Write-Verbose "  Events: $($eventsResult.EventCount ?? 0)"
    Write-Verbose "  Edges: $($edgesResult.EdgeCount ?? 0)"
    #endregion

    #region Phase 3: Unified Indexing (5 indexers)
    Write-Verbose "Phase 3: Indexing data to Cosmos DB with delta detection..."

    # Index Principals (unified: users, groups, SPs, devices)
    $principalsIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }

    # Index each principal type using the unified principals indexer
    if ($usersResult.Success -and $usersResult.PrincipalsBlobName) {
        $usersIndexInput = @{ Timestamp = $timestamp; BlobName = $usersResult.PrincipalsBlobName; PrincipalType = 'user' }
        $usersIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $usersIndexInput
        if ($usersIndexResult.Success) {
            Write-Verbose "Users indexing complete: $($usersIndexResult.TotalPrincipals) total, $($usersIndexResult.NewPrincipals) new"
            $principalsIndexResult.TotalPrincipals += $usersIndexResult.TotalPrincipals
            $principalsIndexResult.NewPrincipals += $usersIndexResult.NewPrincipals
            $principalsIndexResult.ModifiedPrincipals += $usersIndexResult.ModifiedPrincipals
            $principalsIndexResult.CosmosWriteCount += $usersIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Users indexing failed: $($usersIndexResult.Error)"
        }
    }

    if ($groupsResult.Success -and $groupsResult.PrincipalsBlobName) {
        $groupsIndexInput = @{ Timestamp = $timestamp; BlobName = $groupsResult.PrincipalsBlobName; PrincipalType = 'group' }
        $groupsIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $groupsIndexInput
        if ($groupsIndexResult.Success) {
            Write-Verbose "Groups indexing complete: $($groupsIndexResult.TotalPrincipals) total, $($groupsIndexResult.NewPrincipals) new"
            $principalsIndexResult.TotalPrincipals += $groupsIndexResult.TotalPrincipals
            $principalsIndexResult.NewPrincipals += $groupsIndexResult.NewPrincipals
            $principalsIndexResult.ModifiedPrincipals += $groupsIndexResult.ModifiedPrincipals
            $principalsIndexResult.CosmosWriteCount += $groupsIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Groups indexing failed: $($groupsIndexResult.Error)"
        }
    }

    if ($servicePrincipalsResult.Success -and $servicePrincipalsResult.PrincipalsBlobName) {
        $servicePrincipalsIndexInput = @{ Timestamp = $timestamp; BlobName = $servicePrincipalsResult.PrincipalsBlobName; PrincipalType = 'servicePrincipal' }
        $servicePrincipalsIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $servicePrincipalsIndexInput
        if ($servicePrincipalsIndexResult.Success) {
            Write-Verbose "Service Principals indexing complete: $($servicePrincipalsIndexResult.TotalPrincipals) total, $($servicePrincipalsIndexResult.NewPrincipals) new"
            $principalsIndexResult.TotalPrincipals += $servicePrincipalsIndexResult.TotalPrincipals
            $principalsIndexResult.NewPrincipals += $servicePrincipalsIndexResult.NewPrincipals
            $principalsIndexResult.ModifiedPrincipals += $servicePrincipalsIndexResult.ModifiedPrincipals
            $principalsIndexResult.CosmosWriteCount += $servicePrincipalsIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Service Principals indexing failed: $($servicePrincipalsIndexResult.Error)"
        }
    }

    if ($devicesResult.Success -and $devicesResult.PrincipalsBlobName) {
        $devicesIndexInput = @{ Timestamp = $timestamp; BlobName = $devicesResult.PrincipalsBlobName; PrincipalType = 'device' }
        $devicesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $devicesIndexInput
        if ($devicesIndexResult.Success) {
            Write-Verbose "Devices indexing complete: $($devicesIndexResult.TotalPrincipals) total, $($devicesIndexResult.NewPrincipals) new"
            $principalsIndexResult.TotalPrincipals += $devicesIndexResult.TotalPrincipals
            $principalsIndexResult.NewPrincipals += $devicesIndexResult.NewPrincipals
            $principalsIndexResult.ModifiedPrincipals += $devicesIndexResult.ModifiedPrincipals
            $principalsIndexResult.CosmosWriteCount += $devicesIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Devices indexing failed: $($devicesIndexResult.Error)"
        }
    }

    $principalsIndexResult.Success = $true

    # Index Resources (unified: applications + Azure resources + role definitions)
    $resourcesIndexResult = @{ Success = $false; TotalResources = 0; NewResources = 0; ModifiedResources = 0; DeletedResources = 0; UnchangedResources = 0; CosmosWriteCount = 0 }

    if ($applicationsResult.Success -and $applicationsResult.ResourcesBlobName) {
        $applicationsIndexInput = @{ Timestamp = $timestamp; BlobName = $applicationsResult.ResourcesBlobName; ResourceType = 'application' }
        $applicationsIndexResult = Invoke-DurableActivity -FunctionName 'IndexResourcesInCosmosDB' -Input $applicationsIndexInput
        if ($applicationsIndexResult.Success) {
            Write-Verbose "Applications indexing complete: $($applicationsIndexResult.TotalResources) total"
            $resourcesIndexResult.TotalResources += $applicationsIndexResult.TotalResources
            $resourcesIndexResult.NewResources += $applicationsIndexResult.NewResources
            $resourcesIndexResult.ModifiedResources += $applicationsIndexResult.ModifiedResources
            $resourcesIndexResult.CosmosWriteCount += $applicationsIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Applications indexing failed: $($applicationsIndexResult.Error)"
        }
    }

    # Index Azure Hierarchy resources
    if ($azureHierarchyResult.Success -and $azureHierarchyResult.ResourcesBlobName) {
        $indexInput = @{ Timestamp = $timestamp; BlobName = $azureHierarchyResult.ResourcesBlobName }
        $indexResult = Invoke-DurableActivity -FunctionName 'IndexResourcesInCosmosDB' -Input $indexInput
        if ($indexResult.Success) {
            Write-Verbose "Azure Hierarchy resources indexing complete: $($indexResult.TotalResources) total"
            $resourcesIndexResult.TotalResources += $indexResult.TotalResources
            $resourcesIndexResult.NewResources += $indexResult.NewResources
            $resourcesIndexResult.ModifiedResources += $indexResult.ModifiedResources
            $resourcesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
        } else {
            Write-Warning "Azure Hierarchy resources indexing failed: $($indexResult.Error)"
        }
    }

    # V3.5 CONSOLIDATED: Index Azure Resources (all resource types from AzureResourceTypes.psd1)
    if ($azureResourcesResult.Success -and $azureResourcesResult.ResourcesBlobName) {
        $indexInput = @{ Timestamp = $timestamp; BlobName = $azureResourcesResult.ResourcesBlobName }
        $indexResult = Invoke-DurableActivity -FunctionName 'IndexResourcesInCosmosDB' -Input $indexInput
        if ($indexResult.Success) {
            Write-Verbose "Azure Resources indexing complete: $($indexResult.TotalResources) total"
            $resourcesIndexResult.TotalResources += $indexResult.TotalResources
            $resourcesIndexResult.NewResources += $indexResult.NewResources
            $resourcesIndexResult.ModifiedResources += $indexResult.ModifiedResources
            $resourcesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
        } else {
            Write-Warning "Azure Resources indexing failed: $($indexResult.Error)"
        }
    }

    # V3.5 CONSOLIDATED: Index Role Definitions
    if ($roleDefinitionsResult.Success -and $roleDefinitionsResult.ResourcesBlobName) {
        $indexInput = @{ Timestamp = $timestamp; BlobName = $roleDefinitionsResult.ResourcesBlobName }
        $indexResult = Invoke-DurableActivity -FunctionName 'IndexResourcesInCosmosDB' -Input $indexInput
        if ($indexResult.Success) {
            Write-Verbose "Role Definitions indexing complete: $($indexResult.TotalResources) total"
            $resourcesIndexResult.TotalResources += $indexResult.TotalResources
            $resourcesIndexResult.NewResources += $indexResult.NewResources
            $resourcesIndexResult.ModifiedResources += $indexResult.ModifiedResources
            $resourcesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
        } else {
            Write-Warning "Role Definitions indexing failed: $($indexResult.Error)"
        }
    }

    $resourcesIndexResult.Success = $true

    # Index Edges (unified: all relationships)
    $edgesIndexResult = @{ Success = $false; TotalEdges = 0; NewEdges = 0; ModifiedEdges = 0; DeletedEdges = 0; UnchangedEdges = 0; CosmosWriteCount = 0 }

    if ($edgesResult.Success -and $edgesResult.EdgesBlobName) {
        $edgesIndexInput = @{ Timestamp = $timestamp; BlobName = $edgesResult.EdgesBlobName }
        $edgesIndexResult = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' -Input $edgesIndexInput
        if ($edgesIndexResult.Success) {
            Write-Verbose "Edges indexing complete: $($edgesIndexResult.TotalEdges) total, $($edgesIndexResult.NewEdges) new"
        } else {
            Write-Warning "Edges indexing failed: $($edgesIndexResult.Error)"
        }
    }

    # Index Azure Hierarchy edges
    if ($azureHierarchyResult.Success -and $azureHierarchyResult.EdgesBlobName) {
        $indexInput = @{ Timestamp = $timestamp; BlobName = $azureHierarchyResult.EdgesBlobName }
        $indexResult = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' -Input $indexInput
        if ($indexResult.Success) {
            Write-Verbose "Azure Hierarchy edges indexing complete: $($indexResult.TotalEdges) total"
            $edgesIndexResult.TotalEdges += $indexResult.TotalEdges
            $edgesIndexResult.NewEdges += $indexResult.NewEdges
            $edgesIndexResult.ModifiedEdges += $indexResult.ModifiedEdges
            $edgesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
        } else {
            Write-Warning "Azure Hierarchy edges indexing failed: $($indexResult.Error)"
        }
    }

    # V3.5 CONSOLIDATED: Index Azure Resources edges (managed identity associations)
    if ($azureResourcesResult.Success -and $azureResourcesResult.EdgesBlobName) {
        $indexInput = @{ Timestamp = $timestamp; BlobName = $azureResourcesResult.EdgesBlobName }
        $indexResult = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' -Input $indexInput
        if ($indexResult.Success) {
            Write-Verbose "Azure Resources edges indexing complete: $($indexResult.TotalEdges) total"
            $edgesIndexResult.TotalEdges += $indexResult.TotalEdges
            $edgesIndexResult.NewEdges += $indexResult.NewEdges
            $edgesIndexResult.ModifiedEdges += $indexResult.ModifiedEdges
            $edgesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
        } else {
            Write-Warning "Azure Resources edges indexing failed: $($indexResult.Error)"
        }
    }

    # Index Policies (policies container - CA policies)
    $policiesIndexResult = @{ Success = $false; TotalPolicies = 0; NewPolicies = 0; ModifiedPolicies = 0; DeletedPolicies = 0; UnchangedPolicies = 0; CosmosWriteCount = 0 }
    if ($policiesResult.Success -and $policiesResult.BlobName) {
        $policiesIndexInput = @{ Timestamp = $timestamp; BlobName = $policiesResult.BlobName }
        $policiesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPoliciesInCosmosDB' -Input $policiesIndexInput
        if ($policiesIndexResult.Success) {
            Write-Verbose "CA Policies indexing complete: $($policiesIndexResult.TotalPolicies) total, $($policiesIndexResult.NewPolicies) new"
        } else {
            Write-Warning "CA Policies indexing failed: $($policiesIndexResult.Error)"
        }
    }

    # V3.5: Index Intune Policies
    $intunePoliciesIndexResult = @{ Success = $false; TotalPolicies = 0; NewPolicies = 0; ModifiedPolicies = 0; CosmosWriteCount = 0 }
    if ($intunePoliciesResult.Success -and $intunePoliciesResult.BlobName) {
        $intunePoliciesIndexInput = @{ Timestamp = $timestamp; BlobName = $intunePoliciesResult.BlobName }
        $intunePoliciesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPoliciesInCosmosDB' -Input $intunePoliciesIndexInput
        if ($intunePoliciesIndexResult.Success) {
            Write-Verbose "Intune Policies indexing complete: $($intunePoliciesIndexResult.TotalPolicies) total"
            $policiesIndexResult.TotalPolicies += $intunePoliciesIndexResult.TotalPolicies
            $policiesIndexResult.NewPolicies += $intunePoliciesIndexResult.NewPolicies
            $policiesIndexResult.ModifiedPolicies += $intunePoliciesIndexResult.ModifiedPolicies
            $policiesIndexResult.CosmosWriteCount += $intunePoliciesIndexResult.CosmosWriteCount
        } else {
            Write-Warning "Intune Policies indexing failed: $($intunePoliciesIndexResult.Error)"
        }
    }

    # Index Events (events container - append only, no delta)
    $eventsIndexResult = @{ Success = $false; TotalEvents = 0; CosmosWriteCount = 0 }
    if ($eventsResult.Success -and $eventsResult.BlobName) {
        $eventsIndexInput = @{ Timestamp = $timestamp; BlobName = $eventsResult.BlobName }
        $eventsIndexResult = Invoke-DurableActivity -FunctionName 'IndexEventsInCosmosDB' -Input $eventsIndexInput
        if ($eventsIndexResult.Success) {
            Write-Verbose "Events indexing complete: $($eventsIndexResult.TotalEvents) events"
        } else {
            Write-Warning "Events indexing failed: $($eventsIndexResult.Error)"
        }
    }
    #endregion

    #region Phase 4: Derive Edges (2 derivation functions)
    Write-Verbose "Phase 4: Deriving abuse and virtual edges..."

    # Derive Abuse Edges (attack path capabilities from permissions/roles)
    $abuseEdgesResult = @{ Success = $false; DerivedEdgeCount = 0; Statistics = @{} }
    try {
        $abuseEdgesInput = @{ Timestamp = $timestamp }
        $abuseEdgesResult = Invoke-DurableActivity -FunctionName 'DeriveAbuseEdges' -Input $abuseEdgesInput
        if ($abuseEdgesResult.Success) {
            Write-Verbose "Abuse edge derivation complete: $($abuseEdgesResult.DerivedEdgeCount) edges derived"
            Write-Verbose "  Graph Permission Abuse: $($abuseEdgesResult.Statistics.GraphPermissionAbuse ?? 0)"
            Write-Verbose "  Directory Role Abuse: $($abuseEdgesResult.Statistics.DirectoryRoleAbuse ?? 0)"
            Write-Verbose "  Ownership Abuse: $($abuseEdgesResult.Statistics.OwnershipAbuse ?? 0)"
            Write-Verbose "  Azure RBAC Abuse: $($abuseEdgesResult.Statistics.AzureRbacAbuse ?? 0)"
        } else {
            Write-Warning "Abuse edge derivation failed: $($abuseEdgesResult.Error)"
        }
    }
    catch {
        Write-Warning "Abuse edge derivation threw exception: $_"
        $abuseEdgesResult = @{ Success = $false; DerivedEdgeCount = 0; Error = $_.Exception.Message }
    }

    # V3.5: Derive Virtual Edges (policy gate edges from Intune policies)
    $virtualEdgesResult = @{ Success = $false; DerivedEdgeCount = 0; Statistics = @{} }
    try {
        $virtualEdgesInput = @{ Timestamp = $timestamp }
        $virtualEdgesResult = Invoke-DurableActivity -FunctionName 'DeriveVirtualEdges' -Input $virtualEdgesInput
        if ($virtualEdgesResult.Success) {
            Write-Verbose "Virtual edge derivation complete: $($virtualEdgesResult.DerivedEdgeCount) edges derived"
            Write-Verbose "  Compliance Policy Targets: $($virtualEdgesResult.Statistics.CompliancePolicyTargetEdges ?? 0)"
            Write-Verbose "  App Protection Policy Targets: $($virtualEdgesResult.Statistics.AppProtectionPolicyTargetEdges ?? 0)"
        } else {
            Write-Warning "Virtual edge derivation failed: $($virtualEdgesResult.Error)"
        }
    }
    catch {
        Write-Warning "Virtual edge derivation threw exception: $_"
        $virtualEdgesResult = @{ Success = $false; DerivedEdgeCount = 0; Error = $_.Exception.Message }
    }
    #endregion

    #region Build Final Result
    $finalResult = @{
        OrchestrationId = $Context.InstanceId
        Timestamp = $timestampFormatted
        Status = 'Completed'
        Architecture = 'V3.5-Consolidated'

        Collection = @{
            # Principals
            Users = @{
                Success = $usersResult.Success
                Count = $usersResult.UserCount ?? 0
                BlobPath = $usersResult.PrincipalsBlobName
                RiskDataEmbedded = $true
            }
            Groups = @{
                Success = $groupsResult.Success
                Count = $groupsResult.GroupCount ?? 0
                BlobPath = $groupsResult.PrincipalsBlobName
            }
            ServicePrincipals = @{
                Success = $servicePrincipalsResult.Success
                Count = $servicePrincipalsResult.ServicePrincipalCount ?? 0
                BlobPath = $servicePrincipalsResult.PrincipalsBlobName
            }
            Devices = @{
                Success = $devicesResult.Success
                Count = $devicesResult.DeviceCount ?? 0
                BlobPath = $devicesResult.PrincipalsBlobName
            }

            # Resources
            Applications = @{
                Success = $applicationsResult.Success
                Count = $applicationsResult.AppCount ?? 0
                BlobPath = $applicationsResult.ResourcesBlobName
            }
            AzureHierarchy = @{
                Success = $azureHierarchyResult.Success
                Count = $azureHierarchyResult.ResourceCount ?? 0
                ResourcesBlobPath = $azureHierarchyResult.ResourcesBlobName
                EdgesBlobPath = $azureHierarchyResult.EdgesBlobName
            }
            # V3.5 CONSOLIDATED
            AzureResources = @{
                Success = $azureResourcesResult.Success
                Count = $azureResourcesResult.ResourceCount ?? 0
                ResourcesBlobPath = $azureResourcesResult.ResourcesBlobName
                EdgesBlobPath = $azureResourcesResult.EdgesBlobName
                Statistics = $azureResourcesResult.Statistics
            }
            RoleDefinitions = @{
                Success = $roleDefinitionsResult.Success
                Count = $roleDefinitionsResult.RoleDefinitionCount ?? 0
                ResourcesBlobPath = $roleDefinitionsResult.ResourcesBlobName
                Statistics = $roleDefinitionsResult.Statistics
            }

            # Policies
            CAPolicies = @{
                Success = $policiesResult.Success
                Count = $policiesResult.PolicyCount ?? 0
                BlobPath = $policiesResult.BlobName
                Summary = $policiesResult.Summary
            }
            IntunePolicies = @{
                Success = $intunePoliciesResult.Success
                Count = $intunePoliciesResult.PolicyCount ?? 0
                BlobPath = $intunePoliciesResult.BlobName
                Statistics = $intunePoliciesResult.Statistics
            }

            # Edges and Events
            Edges = @{
                Success = $edgesResult.Success
                Count = $edgesResult.EdgeCount ?? 0
                BlobPath = $edgesResult.EdgesBlobName
                Summary = $edgesResult.Summary
            }
            Events = @{
                Success = $eventsResult.Success
                Count = $eventsResult.EventCount ?? 0
                BlobPath = $eventsResult.BlobName
                Summary = $eventsResult.Summary
            }

            # Derived Edges
            AbuseEdges = @{
                Success = $abuseEdgesResult.Success
                Count = $abuseEdgesResult.DerivedEdgeCount ?? 0
                Statistics = $abuseEdgesResult.Statistics
            }
            VirtualEdges = @{
                Success = $virtualEdgesResult.Success
                Count = $virtualEdgesResult.DerivedEdgeCount ?? 0
                Statistics = $virtualEdgesResult.Statistics
            }
        }

        Indexing = @{
            Principals = @{
                Success = $principalsIndexResult.Success
                Total = $principalsIndexResult.TotalPrincipals
                New = $principalsIndexResult.NewPrincipals
                Modified = $principalsIndexResult.ModifiedPrincipals
                CosmosWrites = $principalsIndexResult.CosmosWriteCount
            }
            Resources = @{
                Success = $resourcesIndexResult.Success
                Total = $resourcesIndexResult.TotalResources
                New = $resourcesIndexResult.NewResources
                Modified = $resourcesIndexResult.ModifiedResources
                CosmosWrites = $resourcesIndexResult.CosmosWriteCount
            }
            Edges = @{
                Success = $edgesIndexResult.Success
                Total = $edgesIndexResult.TotalEdges
                New = $edgesIndexResult.NewEdges
                Modified = $edgesIndexResult.ModifiedEdges
                CosmosWrites = $edgesIndexResult.CosmosWriteCount
            }
            Policies = @{
                Success = $policiesIndexResult.Success
                Total = $policiesIndexResult.TotalPolicies
                New = $policiesIndexResult.NewPolicies
                Modified = $policiesIndexResult.ModifiedPolicies
                CosmosWrites = $policiesIndexResult.CosmosWriteCount
            }
            Events = @{
                Success = $eventsIndexResult.Success
                Total = $eventsIndexResult.TotalEvents
                CosmosWrites = $eventsIndexResult.CosmosWriteCount
            }
        }

        Summary = @{
            # Principal counts
            TotalUsers = $usersResult.UserCount ?? 0
            TotalGroups = $groupsResult.GroupCount ?? 0
            TotalServicePrincipals = $servicePrincipalsResult.ServicePrincipalCount ?? 0
            TotalDevices = $devicesResult.DeviceCount ?? 0
            TotalPrincipals = (
                ($usersResult.UserCount ?? 0) +
                ($groupsResult.GroupCount ?? 0) +
                ($servicePrincipalsResult.ServicePrincipalCount ?? 0) +
                ($devicesResult.DeviceCount ?? 0)
            )

            # Resource counts
            TotalApplications = $applicationsResult.AppCount ?? 0
            TotalAzureHierarchyResources = $azureHierarchyResult.ResourceCount ?? 0
            TotalAzureResources = $azureResourcesResult.ResourceCount ?? 0
            TotalRoleDefinitions = $roleDefinitionsResult.RoleDefinitionCount ?? 0
            TotalResources = (
                ($applicationsResult.AppCount ?? 0) +
                ($azureHierarchyResult.ResourceCount ?? 0) +
                ($azureResourcesResult.ResourceCount ?? 0) +
                ($roleDefinitionsResult.RoleDefinitionCount ?? 0)
            )

            # Policy counts
            TotalCAPolicies = $policiesResult.PolicyCount ?? 0
            TotalIntunePolicies = $intunePoliciesResult.PolicyCount ?? 0
            TotalPolicies = (
                ($policiesResult.PolicyCount ?? 0) +
                ($intunePoliciesResult.PolicyCount ?? 0)
            )

            # Edge counts
            TotalEdges = $edgesResult.EdgeCount ?? 0
            TotalAbuseEdges = $abuseEdgesResult.DerivedEdgeCount ?? 0
            TotalVirtualEdges = $virtualEdgesResult.DerivedEdgeCount ?? 0
            TotalDerivedEdges = (
                ($abuseEdgesResult.DerivedEdgeCount ?? 0) +
                ($virtualEdgesResult.DerivedEdgeCount ?? 0)
            )
            TotalEvents = $eventsResult.EventCount ?? 0

            # Indexing summary
            TotalPrincipalsIndexed = $principalsIndexResult.TotalPrincipals
            TotalResourcesIndexed = $resourcesIndexResult.TotalResources
            TotalEdgesIndexed = $edgesIndexResult.TotalEdges
            TotalNewEntities = (
                ($principalsIndexResult.NewPrincipals ?? 0) +
                ($resourcesIndexResult.NewResources ?? 0) +
                ($edgesIndexResult.NewEdges ?? 0) +
                ($policiesIndexResult.NewPolicies ?? 0)
            )
            TotalModifiedEntities = (
                ($principalsIndexResult.ModifiedPrincipals ?? 0) +
                ($resourcesIndexResult.ModifiedResources ?? 0) +
                ($edgesIndexResult.ModifiedEdges ?? 0) +
                ($policiesIndexResult.ModifiedPolicies ?? 0)
            )
            TotalEventsIndexed = $eventsIndexResult.TotalEvents ?? 0

            # Status
            DataInBlob = $true
            AllPrincipalCollectionsSucceeded = (
                $usersResult.Success -and
                $groupsResult.Success -and
                $servicePrincipalsResult.Success -and
                $devicesResult.Success
            )
            AllResourceCollectionsSucceeded = (
                $applicationsResult.Success -and
                $azureHierarchyResult.Success -and
                $azureResourcesResult.Success -and
                $roleDefinitionsResult.Success
            )
            AllPolicyCollectionsSucceeded = (
                $policiesResult.Success -and
                $intunePoliciesResult.Success
            )
            AllIndexingSucceeded = (
                $principalsIndexResult.Success -and
                $resourcesIndexResult.Success -and
                $edgesIndexResult.Success -and
                $policiesIndexResult.Success -and
                $eventsIndexResult.Success
            )
            AllDerivationsSucceeded = (
                $abuseEdgesResult.Success -and
                $virtualEdgesResult.Success
            )
        }
    }

    Write-Verbose "Orchestration complete successfully (V3.5 - Consolidated)"
    Write-Verbose "Principals: $($finalResult.Summary.TotalPrincipals) indexed"
    Write-Verbose "Resources: $($finalResult.Summary.TotalResources) indexed"
    Write-Verbose "Edges: $($finalResult.Summary.TotalEdges) indexed"
    Write-Verbose "Derived Edges: $($finalResult.Summary.TotalDerivedEdges) (abuse + virtual)"
    Write-Verbose "Policies: $($finalResult.Summary.TotalPolicies) (CA + Intune)"
    Write-Verbose "New entities: $($finalResult.Summary.TotalNewEntities), Modified: $($finalResult.Summary.TotalModifiedEntities)"
    Write-Verbose "Events: $($finalResult.Summary.TotalEventsIndexed) indexed"

    return $finalResult
    #endregion
}
catch {
    Write-Error "Orchestration failed: $_"

    return @{
        OrchestrationId = $Context.InstanceId
        Status = 'Failed'
        Error = $_.Exception.Message
        StackTrace = $_.ScriptStackTrace
    }
}

