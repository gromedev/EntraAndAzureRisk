
#region Durable Functions Orchestrator - V2 UNIFIED ARCHITECTURE (15 Collectors)
<#
.SYNOPSIS
    Orchestrates comprehensive Entra and Azure data collection with delta change detection
.DESCRIPTION
    V2 Architecture: Unified Containers with Type Discriminators

    15 Collectors → 4+ Indexers → 7+ Containers

    Phase 1: Principal Collection (Parallel - 5 collectors)
      - CollectUsersWithAuthMethods → users.jsonl (principalType=user)
      - CollectEntraGroups → groups.jsonl (principalType=group)
      - CollectEntraServicePrincipals → serviceprincipals.jsonl (principalType=servicePrincipal)
      - CollectDevices → devices.jsonl (principalType=device)
      - CollectAppRegistrations → applications.jsonl (principalType=application)

    Phase 2: Relationship, Policy, and Event Collection (Parallel - 3 collectors)
      - CollectRelationships → relationships.jsonl (all relationType: groupMember, directoryRole, pimEligible, pimActive, pimGroupEligible, pimGroupActive, azureRbac)
      - CollectPolicies → policies.jsonl (all policyType: conditionalAccess, roleManagement, roleManagementAssignment, namedLocation)
      - CollectEvents → events.jsonl (all eventType: signIn, audit)

    Phase 2.5: Azure Resource Collection (Parallel - 7 collectors)
      - CollectAzureHierarchy → azureresources.jsonl (resourceType: tenant, managementGroup, subscription, resourceGroup)
      - CollectKeyVaults → keyvaults.jsonl (resourceType: keyVault)
      - CollectVirtualMachines → virtualmachines.jsonl (resourceType: virtualMachine)
      - CollectAutomationAccounts → automationaccounts.jsonl (resourceType: automationAccount)
      - CollectFunctionApps → functionapps.jsonl (resourceType: functionApp)
      - CollectLogicApps → logicapps.jsonl (resourceType: logicApp)
      - CollectWebApps → webapps.jsonl (resourceType: webApp)
      + Azure relationships (contains, keyVaultAccess, hasManagedIdentity)

    Phase 3: Unified Indexing (4 indexers)
      - IndexPrincipalsInCosmosDB → principals container
      - IndexRelationshipsInCosmosDB → relationships container
      - IndexPoliciesInCosmosDB → policies container
      - IndexEventsInCosmosDB → events container

    Phase 4: TestAIFoundry - Optional connectivity test

    V2 Benefits:
    - 15 collectors (8 Entra + 7 Azure)
    - Unified containers reduce Cosmos complexity (28 → 7 containers)
    - Type discriminators enable filtering (principalType, relationType, policyType, eventType, resourceType)
    - Denormalized relationship data for Power BI (no joins needed)
    - Preserved delta detection pattern (~99% write reduction)
    - Azure resource hierarchy for attack path analysis
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration (V2 - 15 Collectors)"
    Write-Verbose "Instance ID: $($Context.InstanceId)"

    # Single Get-Date call to prevent race condition
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Verbose "Collection timestamp: $timestampFormatted"

    $collectionInput = @{
        Timestamp = $timestamp
    }

    #region Phase 1: Principal Collection (Parallel - 5 collectors)
    Write-Verbose "Phase 1: Collecting principal data from Entra ID (5 collectors in parallel)..."

    $usersTask = Invoke-DurableActivity `
        -FunctionName 'CollectUsersWithAuthMethods' `
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

    $applicationsTask = Invoke-DurableActivity `
        -FunctionName 'CollectAppRegistrations' `
        -Input $collectionInput `
        -NoWait
    #endregion

    #region Phase 2: Relationship, Policy, Event Collection (Parallel - 3 collectors)
    Write-Verbose "Phase 2: Collecting relationships, policies, and events (3 collectors in parallel)..."

    $relationshipsTask = Invoke-DurableActivity `
        -FunctionName 'CollectRelationships' `
        -Input $collectionInput `
        -NoWait

    $policiesTask = Invoke-DurableActivity `
        -FunctionName 'CollectPolicies' `
        -Input $collectionInput `
        -NoWait

    $eventsTask = Invoke-DurableActivity `
        -FunctionName 'CollectEvents' `
        -Input $collectionInput `
        -NoWait
    #endregion

    #region Phase 2.5: Azure Resource Collection (Parallel - 7 collectors)
    Write-Verbose "Phase 2.5: Collecting Azure resources (7 collectors in parallel)..."

    $azureHierarchyTask = Invoke-DurableActivity `
        -FunctionName 'CollectAzureHierarchy' `
        -Input $collectionInput `
        -NoWait

    $keyVaultsTask = Invoke-DurableActivity `
        -FunctionName 'CollectKeyVaults' `
        -Input $collectionInput `
        -NoWait

    $virtualMachinesTask = Invoke-DurableActivity `
        -FunctionName 'CollectVirtualMachines' `
        -Input $collectionInput `
        -NoWait

    $automationAccountsTask = Invoke-DurableActivity `
        -FunctionName 'CollectAutomationAccounts' `
        -Input $collectionInput `
        -NoWait

    $functionAppsTask = Invoke-DurableActivity `
        -FunctionName 'CollectFunctionApps' `
        -Input $collectionInput `
        -NoWait

    $logicAppsTask = Invoke-DurableActivity `
        -FunctionName 'CollectLogicApps' `
        -Input $collectionInput `
        -NoWait

    $webAppsTask = Invoke-DurableActivity `
        -FunctionName 'CollectWebApps' `
        -Input $collectionInput `
        -NoWait
    #endregion

    #region Wait for All Collections
    Write-Verbose "Waiting for all 15 collectors to complete..."

    $allResults = Wait-ActivityFunction -Task @(
        $usersTask,
        $groupsTask,
        $servicePrincipalsTask,
        $devicesTask,
        $applicationsTask,
        $relationshipsTask,
        $policiesTask,
        $eventsTask,
        $azureHierarchyTask,
        $keyVaultsTask,
        $virtualMachinesTask,
        $automationAccountsTask,
        $functionAppsTask,
        $logicAppsTask,
        $webAppsTask
    )

    $usersResult = $allResults[0]
    $groupsResult = $allResults[1]
    $servicePrincipalsResult = $allResults[2]
    $devicesResult = $allResults[3]
    $applicationsResult = $allResults[4]
    $relationshipsResult = $allResults[5]
    $policiesResult = $allResults[6]
    $eventsResult = $allResults[7]
    $azureHierarchyResult = $allResults[8]
    $keyVaultsResult = $allResults[9]
    $virtualMachinesResult = $allResults[10]
    $automationAccountsResult = $allResults[11]
    $functionAppsResult = $allResults[12]
    $logicAppsResult = $allResults[13]
    $webAppsResult = $allResults[14]
    #endregion

    #region Validate Collection Results
    # Users is critical - fail fast if it fails
    if (-not $usersResult.Success) {
        throw "User collection failed (critical): $($usersResult.Error)"
    }

    # Other collections are non-critical - log warnings but continue
    if (-not $groupsResult.Success) {
        Write-Warning "Groups collection failed: $($groupsResult.Error)"
        $groupsResult = @{ Success = $false; GroupCount = 0; BlobName = $null }
    }

    if (-not $servicePrincipalsResult.Success) {
        Write-Warning "Service Principals collection failed: $($servicePrincipalsResult.Error)"
        $servicePrincipalsResult = @{ Success = $false; ServicePrincipalCount = 0; BlobName = $null }
    }

    if (-not $devicesResult.Success) {
        Write-Warning "Devices collection failed: $($devicesResult.Error)"
        $devicesResult = @{ Success = $false; DeviceCount = 0; BlobName = $null }
    }

    if (-not $applicationsResult.Success) {
        Write-Warning "Applications collection failed: $($applicationsResult.Error)"
        $applicationsResult = @{ Success = $false; AppRegistrationCount = 0; BlobName = $null }
    }

    if (-not $relationshipsResult.Success) {
        Write-Warning "Relationships collection failed: $($relationshipsResult.Error)"
        $relationshipsResult = @{ Success = $false; RelationshipCount = 0; BlobName = $null }
    }

    if (-not $policiesResult.Success) {
        Write-Warning "Policies collection failed: $($policiesResult.Error)"
        $policiesResult = @{ Success = $false; PolicyCount = 0; BlobName = $null }
    }

    if (-not $eventsResult.Success) {
        Write-Warning "Events collection failed: $($eventsResult.Error)"
        $eventsResult = @{ Success = $false; EventCount = 0; BlobName = $null }
    }

    # Azure collectors are non-critical (may not have ARM permissions)
    if (-not $azureHierarchyResult.Success) {
        Write-Warning "Azure hierarchy collection failed: $($azureHierarchyResult.Error)"
        $azureHierarchyResult = @{ Success = $false; ResourceCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $keyVaultsResult.Success) {
        Write-Warning "Key Vaults collection failed: $($keyVaultsResult.Error)"
        $keyVaultsResult = @{ Success = $false; KeyVaultCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $virtualMachinesResult.Success) {
        Write-Warning "Virtual Machines collection failed: $($virtualMachinesResult.Error)"
        $virtualMachinesResult = @{ Success = $false; VirtualMachineCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $automationAccountsResult.Success) {
        Write-Warning "Automation Accounts collection failed: $($automationAccountsResult.Error)"
        $automationAccountsResult = @{ Success = $false; AutomationAccountCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $functionAppsResult.Success) {
        Write-Warning "Function Apps collection failed: $($functionAppsResult.Error)"
        $functionAppsResult = @{ Success = $false; FunctionAppCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $logicAppsResult.Success) {
        Write-Warning "Logic Apps collection failed: $($logicAppsResult.Error)"
        $logicAppsResult = @{ Success = $false; LogicAppCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    if (-not $webAppsResult.Success) {
        Write-Warning "Web Apps collection failed: $($webAppsResult.Error)"
        $webAppsResult = @{ Success = $false; WebAppCount = 0; ResourcesBlobName = $null; RelationshipsBlobName = $null }
    }

    Write-Verbose "Collection complete:"
    Write-Verbose "  Users: $($usersResult.UserCount ?? 0)"
    Write-Verbose "  Groups: $($groupsResult.GroupCount ?? 0)"
    Write-Verbose "  Service Principals: $($servicePrincipalsResult.ServicePrincipalCount ?? 0)"
    Write-Verbose "  Devices: $($devicesResult.DeviceCount ?? 0)"
    Write-Verbose "  Applications: $($applicationsResult.AppRegistrationCount ?? 0)"
    Write-Verbose "  Relationships: $($relationshipsResult.RelationshipCount ?? 0)"
    Write-Verbose "  Policies: $($policiesResult.PolicyCount ?? 0)"
    Write-Verbose "  Events: $($eventsResult.EventCount ?? 0)"
    Write-Verbose "  Azure Hierarchy: $($azureHierarchyResult.ResourceCount ?? 0) resources"
    Write-Verbose "  Key Vaults: $($keyVaultsResult.KeyVaultCount ?? 0)"
    Write-Verbose "  Virtual Machines: $($virtualMachinesResult.VirtualMachineCount ?? 0)"
    Write-Verbose "  Automation Accounts: $($automationAccountsResult.AutomationAccountCount ?? 0)"
    Write-Verbose "  Function Apps: $($functionAppsResult.FunctionAppCount ?? 0)"
    Write-Verbose "  Logic Apps: $($logicAppsResult.LogicAppCount ?? 0)"
    Write-Verbose "  Web Apps: $($webAppsResult.WebAppCount ?? 0)"
    #endregion

    #region Phase 3: Unified Indexing (4 indexers)
    Write-Verbose "Phase 3: Indexing data to Cosmos DB with delta detection..."

    # Index Users (principals container)
    $usersIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }
    if ($usersResult.Success -and $usersResult.UsersBlobName) {
        $usersIndexInput = @{ Timestamp = $timestamp; BlobName = $usersResult.UsersBlobName }
        $usersIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $usersIndexInput
        if ($usersIndexResult.Success) {
            Write-Verbose "Users indexing complete: $($usersIndexResult.TotalPrincipals) total, $($usersIndexResult.NewPrincipals) new"
        } else {
            Write-Warning "Users indexing failed: $($usersIndexResult.Error)"
        }
    }

    # Index Groups (principals container)
    $groupsIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }
    if ($groupsResult.Success -and $groupsResult.BlobName) {
        $groupsIndexInput = @{ Timestamp = $timestamp; BlobName = $groupsResult.BlobName }
        $groupsIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $groupsIndexInput
        if ($groupsIndexResult.Success) {
            Write-Verbose "Groups indexing complete: $($groupsIndexResult.TotalPrincipals) total, $($groupsIndexResult.NewPrincipals) new"
        } else {
            Write-Warning "Groups indexing failed: $($groupsIndexResult.Error)"
        }
    }

    # Index Service Principals (principals container)
    $servicePrincipalsIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }
    if ($servicePrincipalsResult.Success -and $servicePrincipalsResult.BlobName) {
        $servicePrincipalsIndexInput = @{ Timestamp = $timestamp; BlobName = $servicePrincipalsResult.BlobName }
        $servicePrincipalsIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $servicePrincipalsIndexInput
        if ($servicePrincipalsIndexResult.Success) {
            Write-Verbose "Service Principals indexing complete: $($servicePrincipalsIndexResult.TotalPrincipals) total, $($servicePrincipalsIndexResult.NewPrincipals) new"
        } else {
            Write-Warning "Service Principals indexing failed: $($servicePrincipalsIndexResult.Error)"
        }
    }

    # Index Devices (principals container)
    $devicesIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }
    if ($devicesResult.Success -and $devicesResult.BlobName) {
        $devicesIndexInput = @{ Timestamp = $timestamp; BlobName = $devicesResult.BlobName }
        $devicesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $devicesIndexInput
        if ($devicesIndexResult.Success) {
            Write-Verbose "Devices indexing complete: $($devicesIndexResult.TotalPrincipals) total, $($devicesIndexResult.NewPrincipals) new"
        } else {
            Write-Warning "Devices indexing failed: $($devicesIndexResult.Error)"
        }
    }

    # Index Applications (principals container)
    $applicationsIndexResult = @{ Success = $false; TotalPrincipals = 0; NewPrincipals = 0; ModifiedPrincipals = 0; DeletedPrincipals = 0; UnchangedPrincipals = 0; CosmosWriteCount = 0 }
    if ($applicationsResult.Success -and $applicationsResult.BlobName) {
        $applicationsIndexInput = @{ Timestamp = $timestamp; BlobName = $applicationsResult.BlobName }
        $applicationsIndexResult = Invoke-DurableActivity -FunctionName 'IndexPrincipalsInCosmosDB' -Input $applicationsIndexInput
        if ($applicationsIndexResult.Success) {
            Write-Verbose "Applications indexing complete: $($applicationsIndexResult.TotalPrincipals) total, $($applicationsIndexResult.NewPrincipals) new"
        } else {
            Write-Warning "Applications indexing failed: $($applicationsIndexResult.Error)"
        }
    }

    # Index Relationships (relationships container)
    $relationshipsIndexResult = @{ Success = $false; TotalRelationships = 0; NewRelationships = 0; ModifiedRelationships = 0; DeletedRelationships = 0; UnchangedRelationships = 0; CosmosWriteCount = 0 }
    if ($relationshipsResult.Success -and $relationshipsResult.BlobName) {
        $relationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $relationshipsResult.BlobName }
        $relationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexRelationshipsInCosmosDB' -Input $relationshipsIndexInput
        if ($relationshipsIndexResult.Success) {
            Write-Verbose "Relationships indexing complete: $($relationshipsIndexResult.TotalRelationships) total, $($relationshipsIndexResult.NewRelationships) new"
        } else {
            Write-Warning "Relationships indexing failed: $($relationshipsIndexResult.Error)"
        }
    }

    # Index Policies (policies container)
    $policiesIndexResult = @{ Success = $false; TotalPolicies = 0; NewPolicies = 0; ModifiedPolicies = 0; DeletedPolicies = 0; UnchangedPolicies = 0; CosmosWriteCount = 0 }
    if ($policiesResult.Success -and $policiesResult.BlobName) {
        $policiesIndexInput = @{ Timestamp = $timestamp; BlobName = $policiesResult.BlobName }
        $policiesIndexResult = Invoke-DurableActivity -FunctionName 'IndexPoliciesInCosmosDB' -Input $policiesIndexInput
        if ($policiesIndexResult.Success) {
            Write-Verbose "Policies indexing complete: $($policiesIndexResult.TotalPolicies) total, $($policiesIndexResult.NewPolicies) new"
        } else {
            Write-Warning "Policies indexing failed: $($policiesIndexResult.Error)"
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

    # Index Azure Resources (azureResources container)
    $azureHierarchyResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($azureHierarchyResult.Success -and $azureHierarchyResult.ResourcesBlobName) {
        $azureHierarchyResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $azureHierarchyResult.ResourcesBlobName }
        $azureHierarchyResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $azureHierarchyResourcesIndexInput
        if ($azureHierarchyResourcesIndexResult.Success) {
            Write-Verbose "Azure Hierarchy resources indexing complete: $($azureHierarchyResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Azure Hierarchy resources indexing failed: $($azureHierarchyResourcesIndexResult.Error)"
        }
    }

    $keyVaultsResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($keyVaultsResult.Success -and $keyVaultsResult.ResourcesBlobName) {
        $keyVaultsResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $keyVaultsResult.ResourcesBlobName }
        $keyVaultsResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $keyVaultsResourcesIndexInput
        if ($keyVaultsResourcesIndexResult.Success) {
            Write-Verbose "Key Vaults resources indexing complete: $($keyVaultsResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Key Vaults resources indexing failed: $($keyVaultsResourcesIndexResult.Error)"
        }
    }

    $virtualMachinesResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($virtualMachinesResult.Success -and $virtualMachinesResult.ResourcesBlobName) {
        $virtualMachinesResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $virtualMachinesResult.ResourcesBlobName }
        $virtualMachinesResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $virtualMachinesResourcesIndexInput
        if ($virtualMachinesResourcesIndexResult.Success) {
            Write-Verbose "Virtual Machines resources indexing complete: $($virtualMachinesResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Virtual Machines resources indexing failed: $($virtualMachinesResourcesIndexResult.Error)"
        }
    }

    $automationAccountsResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($automationAccountsResult.Success -and $automationAccountsResult.ResourcesBlobName) {
        $automationAccountsResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $automationAccountsResult.ResourcesBlobName }
        $automationAccountsResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $automationAccountsResourcesIndexInput
        if ($automationAccountsResourcesIndexResult.Success) {
            Write-Verbose "Automation Accounts resources indexing complete: $($automationAccountsResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Automation Accounts resources indexing failed: $($automationAccountsResourcesIndexResult.Error)"
        }
    }

    $functionAppsResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($functionAppsResult.Success -and $functionAppsResult.ResourcesBlobName) {
        $functionAppsResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $functionAppsResult.ResourcesBlobName }
        $functionAppsResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $functionAppsResourcesIndexInput
        if ($functionAppsResourcesIndexResult.Success) {
            Write-Verbose "Function Apps resources indexing complete: $($functionAppsResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Function Apps resources indexing failed: $($functionAppsResourcesIndexResult.Error)"
        }
    }

    $logicAppsResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($logicAppsResult.Success -and $logicAppsResult.ResourcesBlobName) {
        $logicAppsResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $logicAppsResult.ResourcesBlobName }
        $logicAppsResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $logicAppsResourcesIndexInput
        if ($logicAppsResourcesIndexResult.Success) {
            Write-Verbose "Logic Apps resources indexing complete: $($logicAppsResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Logic Apps resources indexing failed: $($logicAppsResourcesIndexResult.Error)"
        }
    }

    $webAppsResourcesIndexResult = @{ Success = $false; TotalAzureResources = 0; NewAzureResources = 0; ModifiedAzureResources = 0; DeletedAzureResources = 0; UnchangedAzureResources = 0; CosmosWriteCount = 0 }
    if ($webAppsResult.Success -and $webAppsResult.ResourcesBlobName) {
        $webAppsResourcesIndexInput = @{ Timestamp = $timestamp; BlobName = $webAppsResult.ResourcesBlobName }
        $webAppsResourcesIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureResourcesInCosmosDB' -Input $webAppsResourcesIndexInput
        if ($webAppsResourcesIndexResult.Success) {
            Write-Verbose "Web Apps resources indexing complete: $($webAppsResourcesIndexResult.TotalAzureResources) total"
        } else {
            Write-Warning "Web Apps resources indexing failed: $($webAppsResourcesIndexResult.Error)"
        }
    }

    # Index Azure Relationships (azureRelationships container)
    $azureHierarchyRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($azureHierarchyResult.Success -and $azureHierarchyResult.RelationshipsBlobName) {
        $azureHierarchyRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $azureHierarchyResult.RelationshipsBlobName }
        $azureHierarchyRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $azureHierarchyRelationshipsIndexInput
        if ($azureHierarchyRelationshipsIndexResult.Success) {
            Write-Verbose "Azure Hierarchy relationships indexing complete: $($azureHierarchyRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Azure Hierarchy relationships indexing failed: $($azureHierarchyRelationshipsIndexResult.Error)"
        }
    }

    $keyVaultsRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($keyVaultsResult.Success -and $keyVaultsResult.RelationshipsBlobName) {
        $keyVaultsRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $keyVaultsResult.RelationshipsBlobName }
        $keyVaultsRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $keyVaultsRelationshipsIndexInput
        if ($keyVaultsRelationshipsIndexResult.Success) {
            Write-Verbose "Key Vaults relationships indexing complete: $($keyVaultsRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Key Vaults relationships indexing failed: $($keyVaultsRelationshipsIndexResult.Error)"
        }
    }

    $virtualMachinesRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($virtualMachinesResult.Success -and $virtualMachinesResult.RelationshipsBlobName) {
        $virtualMachinesRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $virtualMachinesResult.RelationshipsBlobName }
        $virtualMachinesRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $virtualMachinesRelationshipsIndexInput
        if ($virtualMachinesRelationshipsIndexResult.Success) {
            Write-Verbose "Virtual Machines relationships indexing complete: $($virtualMachinesRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Virtual Machines relationships indexing failed: $($virtualMachinesRelationshipsIndexResult.Error)"
        }
    }

    $automationAccountsRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($automationAccountsResult.Success -and $automationAccountsResult.RelationshipsBlobName) {
        $automationAccountsRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $automationAccountsResult.RelationshipsBlobName }
        $automationAccountsRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $automationAccountsRelationshipsIndexInput
        if ($automationAccountsRelationshipsIndexResult.Success) {
            Write-Verbose "Automation Accounts relationships indexing complete: $($automationAccountsRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Automation Accounts relationships indexing failed: $($automationAccountsRelationshipsIndexResult.Error)"
        }
    }

    $functionAppsRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($functionAppsResult.Success -and $functionAppsResult.RelationshipsBlobName) {
        $functionAppsRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $functionAppsResult.RelationshipsBlobName }
        $functionAppsRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $functionAppsRelationshipsIndexInput
        if ($functionAppsRelationshipsIndexResult.Success) {
            Write-Verbose "Function Apps relationships indexing complete: $($functionAppsRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Function Apps relationships indexing failed: $($functionAppsRelationshipsIndexResult.Error)"
        }
    }

    $logicAppsRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($logicAppsResult.Success -and $logicAppsResult.RelationshipsBlobName) {
        $logicAppsRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $logicAppsResult.RelationshipsBlobName }
        $logicAppsRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $logicAppsRelationshipsIndexInput
        if ($logicAppsRelationshipsIndexResult.Success) {
            Write-Verbose "Logic Apps relationships indexing complete: $($logicAppsRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Logic Apps relationships indexing failed: $($logicAppsRelationshipsIndexResult.Error)"
        }
    }

    $webAppsRelationshipsIndexResult = @{ Success = $false; TotalAzureRelationships = 0; NewAzureRelationships = 0; ModifiedAzureRelationships = 0; DeletedAzureRelationships = 0; UnchangedAzureRelationships = 0; CosmosWriteCount = 0 }
    if ($webAppsResult.Success -and $webAppsResult.RelationshipsBlobName) {
        $webAppsRelationshipsIndexInput = @{ Timestamp = $timestamp; BlobName = $webAppsResult.RelationshipsBlobName }
        $webAppsRelationshipsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAzureRelationshipsInCosmosDB' -Input $webAppsRelationshipsIndexInput
        if ($webAppsRelationshipsIndexResult.Success) {
            Write-Verbose "Web Apps relationships indexing complete: $($webAppsRelationshipsIndexResult.TotalAzureRelationships) total"
        } else {
            Write-Warning "Web Apps relationships indexing failed: $($webAppsRelationshipsIndexResult.Error)"
        }
    }
    #endregion

    #region Phase 4: Test AI Foundry (Optional)
    Write-Verbose "Phase 4: Testing AI Foundry connectivity..."

    $aiTestInput = @{
        Timestamp = $timestamp
        UserCount = $usersResult.UserCount ?? 0
        GroupCount = $groupsResult.GroupCount ?? 0
        ServicePrincipalCount = $servicePrincipalsResult.ServicePrincipalCount ?? 0
        DeviceCount = $devicesResult.DeviceCount ?? 0
        AppRegistrationCount = $applicationsResult.AppRegistrationCount ?? 0
        RelationshipCount = $relationshipsResult.RelationshipCount ?? 0
        PolicyCount = $policiesResult.PolicyCount ?? 0
        EventCount = $eventsResult.EventCount ?? 0
    }

    $aiTestResult = Invoke-DurableActivity `
        -FunctionName 'TestAIFoundry' `
        -Input $aiTestInput

    if ($aiTestResult.Success) {
        Write-Verbose "AI Foundry test successful"
    } else {
        Write-Verbose "AI Foundry test skipped or failed (non-critical)"
    }
    #endregion

    #region Build Final Result
    $finalResult = @{
        OrchestrationId = $Context.InstanceId
        Timestamp = $timestampFormatted
        Status = 'Completed'
        Architecture = 'V2-15Collectors'

        Collection = @{
            Users = @{
                Success = $usersResult.Success
                Count = $usersResult.UserCount ?? 0
                BlobPath = $usersResult.UsersBlobName
            }
            Groups = @{
                Success = $groupsResult.Success
                Count = $groupsResult.GroupCount ?? 0
                BlobPath = $groupsResult.BlobName
            }
            ServicePrincipals = @{
                Success = $servicePrincipalsResult.Success
                Count = $servicePrincipalsResult.ServicePrincipalCount ?? 0
                BlobPath = $servicePrincipalsResult.BlobName
            }
            Devices = @{
                Success = $devicesResult.Success
                Count = $devicesResult.DeviceCount ?? 0
                BlobPath = $devicesResult.BlobName
            }
            Applications = @{
                Success = $applicationsResult.Success
                Count = $applicationsResult.AppRegistrationCount ?? 0
                BlobPath = $applicationsResult.BlobName
            }
            Relationships = @{
                Success = $relationshipsResult.Success
                Count = $relationshipsResult.RelationshipCount ?? 0
                BlobPath = $relationshipsResult.BlobName
                Summary = $relationshipsResult.Summary
            }
            Policies = @{
                Success = $policiesResult.Success
                Count = $policiesResult.PolicyCount ?? 0
                BlobPath = $policiesResult.BlobName
                Summary = $policiesResult.Summary
            }
            Events = @{
                Success = $eventsResult.Success
                Count = $eventsResult.EventCount ?? 0
                BlobPath = $eventsResult.BlobName
                Summary = $eventsResult.Summary
            }
            # Azure Resources (Phase 2)
            AzureHierarchy = @{
                Success = $azureHierarchyResult.Success
                Count = $azureHierarchyResult.ResourceCount ?? 0
                ResourcesBlobPath = $azureHierarchyResult.ResourcesBlobName
                RelationshipsBlobPath = $azureHierarchyResult.RelationshipsBlobName
                Summary = $azureHierarchyResult.Summary
            }
            KeyVaults = @{
                Success = $keyVaultsResult.Success
                Count = $keyVaultsResult.KeyVaultCount ?? 0
                ResourcesBlobPath = $keyVaultsResult.ResourcesBlobName
                RelationshipsBlobPath = $keyVaultsResult.RelationshipsBlobName
                Summary = $keyVaultsResult.Summary
            }
            VirtualMachines = @{
                Success = $virtualMachinesResult.Success
                Count = $virtualMachinesResult.VirtualMachineCount ?? 0
                ResourcesBlobPath = $virtualMachinesResult.ResourcesBlobName
                RelationshipsBlobPath = $virtualMachinesResult.RelationshipsBlobName
                Summary = $virtualMachinesResult.Summary
            }
            AutomationAccounts = @{
                Success = $automationAccountsResult.Success
                Count = $automationAccountsResult.AutomationAccountCount ?? 0
                ResourcesBlobPath = $automationAccountsResult.ResourcesBlobName
                RelationshipsBlobPath = $automationAccountsResult.RelationshipsBlobName
                Summary = $automationAccountsResult.Summary
            }
            FunctionApps = @{
                Success = $functionAppsResult.Success
                Count = $functionAppsResult.FunctionAppCount ?? 0
                ResourcesBlobPath = $functionAppsResult.ResourcesBlobName
                RelationshipsBlobPath = $functionAppsResult.RelationshipsBlobName
                Summary = $functionAppsResult.Summary
            }
            LogicApps = @{
                Success = $logicAppsResult.Success
                Count = $logicAppsResult.LogicAppCount ?? 0
                ResourcesBlobPath = $logicAppsResult.ResourcesBlobName
                RelationshipsBlobPath = $logicAppsResult.RelationshipsBlobName
                Summary = $logicAppsResult.Summary
            }
            WebApps = @{
                Success = $webAppsResult.Success
                Count = $webAppsResult.WebAppCount ?? 0
                ResourcesBlobPath = $webAppsResult.ResourcesBlobName
                RelationshipsBlobPath = $webAppsResult.RelationshipsBlobName
                Summary = $webAppsResult.Summary
            }
        }

        Indexing = @{
            Principals = @{
                Users = @{
                    Success = $usersIndexResult.Success
                    Total = $usersIndexResult.TotalPrincipals
                    New = $usersIndexResult.NewPrincipals
                    Modified = $usersIndexResult.ModifiedPrincipals
                    Deleted = $usersIndexResult.DeletedPrincipals
                    Unchanged = $usersIndexResult.UnchangedPrincipals
                    CosmosWrites = $usersIndexResult.CosmosWriteCount
                }
                Groups = @{
                    Success = $groupsIndexResult.Success
                    Total = $groupsIndexResult.TotalPrincipals
                    New = $groupsIndexResult.NewPrincipals
                    Modified = $groupsIndexResult.ModifiedPrincipals
                    Deleted = $groupsIndexResult.DeletedPrincipals
                    Unchanged = $groupsIndexResult.UnchangedPrincipals
                    CosmosWrites = $groupsIndexResult.CosmosWriteCount
                }
                ServicePrincipals = @{
                    Success = $servicePrincipalsIndexResult.Success
                    Total = $servicePrincipalsIndexResult.TotalPrincipals
                    New = $servicePrincipalsIndexResult.NewPrincipals
                    Modified = $servicePrincipalsIndexResult.ModifiedPrincipals
                    Deleted = $servicePrincipalsIndexResult.DeletedPrincipals
                    Unchanged = $servicePrincipalsIndexResult.UnchangedPrincipals
                    CosmosWrites = $servicePrincipalsIndexResult.CosmosWriteCount
                }
                Devices = @{
                    Success = $devicesIndexResult.Success
                    Total = $devicesIndexResult.TotalPrincipals
                    New = $devicesIndexResult.NewPrincipals
                    Modified = $devicesIndexResult.ModifiedPrincipals
                    Deleted = $devicesIndexResult.DeletedPrincipals
                    Unchanged = $devicesIndexResult.UnchangedPrincipals
                    CosmosWrites = $devicesIndexResult.CosmosWriteCount
                }
                Applications = @{
                    Success = $applicationsIndexResult.Success
                    Total = $applicationsIndexResult.TotalPrincipals
                    New = $applicationsIndexResult.NewPrincipals
                    Modified = $applicationsIndexResult.ModifiedPrincipals
                    Deleted = $applicationsIndexResult.DeletedPrincipals
                    Unchanged = $applicationsIndexResult.UnchangedPrincipals
                    CosmosWrites = $applicationsIndexResult.CosmosWriteCount
                }
            }
            Relationships = @{
                Success = $relationshipsIndexResult.Success
                Total = $relationshipsIndexResult.TotalRelationships
                New = $relationshipsIndexResult.NewRelationships
                Modified = $relationshipsIndexResult.ModifiedRelationships
                Deleted = $relationshipsIndexResult.DeletedRelationships
                Unchanged = $relationshipsIndexResult.UnchangedRelationships
                CosmosWrites = $relationshipsIndexResult.CosmosWriteCount
            }
            Policies = @{
                Success = $policiesIndexResult.Success
                Total = $policiesIndexResult.TotalPolicies
                New = $policiesIndexResult.NewPolicies
                Modified = $policiesIndexResult.ModifiedPolicies
                Deleted = $policiesIndexResult.DeletedPolicies
                Unchanged = $policiesIndexResult.UnchangedPolicies
                CosmosWrites = $policiesIndexResult.CosmosWriteCount
            }
            Events = @{
                Success = $eventsIndexResult.Success
                Total = $eventsIndexResult.TotalEvents
                CosmosWrites = $eventsIndexResult.CosmosWriteCount
            }
            AzureResources = @{
                Hierarchy = @{
                    Success = $azureHierarchyResourcesIndexResult.Success
                    Total = $azureHierarchyResourcesIndexResult.TotalAzureResources
                    New = $azureHierarchyResourcesIndexResult.NewAzureResources
                    Modified = $azureHierarchyResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $azureHierarchyResourcesIndexResult.CosmosWriteCount
                }
                KeyVaults = @{
                    Success = $keyVaultsResourcesIndexResult.Success
                    Total = $keyVaultsResourcesIndexResult.TotalAzureResources
                    New = $keyVaultsResourcesIndexResult.NewAzureResources
                    Modified = $keyVaultsResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $keyVaultsResourcesIndexResult.CosmosWriteCount
                }
                VirtualMachines = @{
                    Success = $virtualMachinesResourcesIndexResult.Success
                    Total = $virtualMachinesResourcesIndexResult.TotalAzureResources
                    New = $virtualMachinesResourcesIndexResult.NewAzureResources
                    Modified = $virtualMachinesResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $virtualMachinesResourcesIndexResult.CosmosWriteCount
                }
                AutomationAccounts = @{
                    Success = $automationAccountsResourcesIndexResult.Success
                    Total = $automationAccountsResourcesIndexResult.TotalAzureResources
                    New = $automationAccountsResourcesIndexResult.NewAzureResources
                    Modified = $automationAccountsResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $automationAccountsResourcesIndexResult.CosmosWriteCount
                }
                FunctionApps = @{
                    Success = $functionAppsResourcesIndexResult.Success
                    Total = $functionAppsResourcesIndexResult.TotalAzureResources
                    New = $functionAppsResourcesIndexResult.NewAzureResources
                    Modified = $functionAppsResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $functionAppsResourcesIndexResult.CosmosWriteCount
                }
                LogicApps = @{
                    Success = $logicAppsResourcesIndexResult.Success
                    Total = $logicAppsResourcesIndexResult.TotalAzureResources
                    New = $logicAppsResourcesIndexResult.NewAzureResources
                    Modified = $logicAppsResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $logicAppsResourcesIndexResult.CosmosWriteCount
                }
                WebApps = @{
                    Success = $webAppsResourcesIndexResult.Success
                    Total = $webAppsResourcesIndexResult.TotalAzureResources
                    New = $webAppsResourcesIndexResult.NewAzureResources
                    Modified = $webAppsResourcesIndexResult.ModifiedAzureResources
                    CosmosWrites = $webAppsResourcesIndexResult.CosmosWriteCount
                }
            }
            AzureRelationships = @{
                Hierarchy = @{
                    Success = $azureHierarchyRelationshipsIndexResult.Success
                    Total = $azureHierarchyRelationshipsIndexResult.TotalAzureRelationships
                    New = $azureHierarchyRelationshipsIndexResult.NewAzureRelationships
                    Modified = $azureHierarchyRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $azureHierarchyRelationshipsIndexResult.CosmosWriteCount
                }
                KeyVaults = @{
                    Success = $keyVaultsRelationshipsIndexResult.Success
                    Total = $keyVaultsRelationshipsIndexResult.TotalAzureRelationships
                    New = $keyVaultsRelationshipsIndexResult.NewAzureRelationships
                    Modified = $keyVaultsRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $keyVaultsRelationshipsIndexResult.CosmosWriteCount
                }
                VirtualMachines = @{
                    Success = $virtualMachinesRelationshipsIndexResult.Success
                    Total = $virtualMachinesRelationshipsIndexResult.TotalAzureRelationships
                    New = $virtualMachinesRelationshipsIndexResult.NewAzureRelationships
                    Modified = $virtualMachinesRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $virtualMachinesRelationshipsIndexResult.CosmosWriteCount
                }
                AutomationAccounts = @{
                    Success = $automationAccountsRelationshipsIndexResult.Success
                    Total = $automationAccountsRelationshipsIndexResult.TotalAzureRelationships
                    New = $automationAccountsRelationshipsIndexResult.NewAzureRelationships
                    Modified = $automationAccountsRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $automationAccountsRelationshipsIndexResult.CosmosWriteCount
                }
                FunctionApps = @{
                    Success = $functionAppsRelationshipsIndexResult.Success
                    Total = $functionAppsRelationshipsIndexResult.TotalAzureRelationships
                    New = $functionAppsRelationshipsIndexResult.NewAzureRelationships
                    Modified = $functionAppsRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $functionAppsRelationshipsIndexResult.CosmosWriteCount
                }
                LogicApps = @{
                    Success = $logicAppsRelationshipsIndexResult.Success
                    Total = $logicAppsRelationshipsIndexResult.TotalAzureRelationships
                    New = $logicAppsRelationshipsIndexResult.NewAzureRelationships
                    Modified = $logicAppsRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $logicAppsRelationshipsIndexResult.CosmosWriteCount
                }
                WebApps = @{
                    Success = $webAppsRelationshipsIndexResult.Success
                    Total = $webAppsRelationshipsIndexResult.TotalAzureRelationships
                    New = $webAppsRelationshipsIndexResult.NewAzureRelationships
                    Modified = $webAppsRelationshipsIndexResult.ModifiedAzureRelationships
                    CosmosWrites = $webAppsRelationshipsIndexResult.CosmosWriteCount
                }
            }
        }

        AIFoundry = @{
            Success = $aiTestResult.Success
            Message = $aiTestResult.Message
        }

        Summary = @{
            # Entity counts
            TotalUsers = $usersResult.UserCount ?? 0
            TotalGroups = $groupsResult.GroupCount ?? 0
            TotalServicePrincipals = $servicePrincipalsResult.ServicePrincipalCount ?? 0
            TotalDevices = $devicesResult.DeviceCount ?? 0
            TotalApplications = $applicationsResult.AppRegistrationCount ?? 0
            TotalRelationships = $relationshipsResult.RelationshipCount ?? 0
            TotalPolicies = $policiesResult.PolicyCount ?? 0
            TotalEvents = $eventsResult.EventCount ?? 0

            # Azure resource counts (Phase 2 + Phase 3)
            TotalAzureHierarchyResources = $azureHierarchyResult.ResourceCount ?? 0
            TotalKeyVaults = $keyVaultsResult.KeyVaultCount ?? 0
            TotalVirtualMachines = $virtualMachinesResult.VirtualMachineCount ?? 0
            TotalAutomationAccounts = $automationAccountsResult.AutomationAccountCount ?? 0
            TotalFunctionApps = $functionAppsResult.FunctionAppCount ?? 0
            TotalLogicApps = $logicAppsResult.LogicAppCount ?? 0
            TotalWebApps = $webAppsResult.WebAppCount ?? 0
            TotalAzureRelationships = (
                ($azureHierarchyResult.RelationshipCount ?? 0) +
                ($keyVaultsResult.RelationshipCount ?? 0) +
                ($virtualMachinesResult.RelationshipCount ?? 0) +
                ($automationAccountsResult.RelationshipCount ?? 0) +
                ($functionAppsResult.RelationshipCount ?? 0) +
                ($logicAppsResult.RelationshipCount ?? 0) +
                ($webAppsResult.RelationshipCount ?? 0)
            )

            # Indexing summary
            TotalPrincipalsIndexed = (
                ($usersIndexResult.TotalPrincipals ?? 0) +
                ($groupsIndexResult.TotalPrincipals ?? 0) +
                ($servicePrincipalsIndexResult.TotalPrincipals ?? 0) +
                ($devicesIndexResult.TotalPrincipals ?? 0) +
                ($applicationsIndexResult.TotalPrincipals ?? 0)
            )
            TotalNewEntities = (
                ($usersIndexResult.NewPrincipals ?? 0) +
                ($groupsIndexResult.NewPrincipals ?? 0) +
                ($servicePrincipalsIndexResult.NewPrincipals ?? 0) +
                ($devicesIndexResult.NewPrincipals ?? 0) +
                ($applicationsIndexResult.NewPrincipals ?? 0) +
                ($relationshipsIndexResult.NewRelationships ?? 0) +
                ($policiesIndexResult.NewPolicies ?? 0)
            )
            TotalModifiedEntities = (
                ($usersIndexResult.ModifiedPrincipals ?? 0) +
                ($groupsIndexResult.ModifiedPrincipals ?? 0) +
                ($servicePrincipalsIndexResult.ModifiedPrincipals ?? 0) +
                ($devicesIndexResult.ModifiedPrincipals ?? 0) +
                ($applicationsIndexResult.ModifiedPrincipals ?? 0) +
                ($relationshipsIndexResult.ModifiedRelationships ?? 0) +
                ($policiesIndexResult.ModifiedPolicies ?? 0)
            )
            TotalEventsIndexed = $eventsIndexResult.TotalEvents ?? 0

            # Status
            DataInBlob = $true
            AllEntraCollectionsSucceeded = (
                $usersResult.Success -and
                $groupsResult.Success -and
                $servicePrincipalsResult.Success -and
                $devicesResult.Success -and
                $applicationsResult.Success -and
                $relationshipsResult.Success -and
                $policiesResult.Success -and
                $eventsResult.Success
            )
            AllAzureCollectionsSucceeded = (
                $azureHierarchyResult.Success -and
                $keyVaultsResult.Success -and
                $virtualMachinesResult.Success -and
                $automationAccountsResult.Success -and
                $functionAppsResult.Success -and
                $logicAppsResult.Success -and
                $webAppsResult.Success
            )
            AllIndexingSucceeded = (
                $usersIndexResult.Success -and
                $groupsIndexResult.Success -and
                $servicePrincipalsIndexResult.Success -and
                $devicesIndexResult.Success -and
                $applicationsIndexResult.Success -and
                $relationshipsIndexResult.Success -and
                $policiesIndexResult.Success -and
                $eventsIndexResult.Success
            )
            AllAzureIndexingSucceeded = (
                $azureHierarchyResourcesIndexResult.Success -and
                $keyVaultsResourcesIndexResult.Success -and
                $virtualMachinesResourcesIndexResult.Success -and
                $automationAccountsResourcesIndexResult.Success -and
                $functionAppsResourcesIndexResult.Success -and
                $logicAppsResourcesIndexResult.Success -and
                $webAppsResourcesIndexResult.Success -and
                $azureHierarchyRelationshipsIndexResult.Success -and
                $keyVaultsRelationshipsIndexResult.Success -and
                $virtualMachinesRelationshipsIndexResult.Success -and
                $automationAccountsRelationshipsIndexResult.Success -and
                $functionAppsRelationshipsIndexResult.Success -and
                $logicAppsRelationshipsIndexResult.Success -and
                $webAppsRelationshipsIndexResult.Success
            )
            TotalAzureResourcesIndexed = (
                ($azureHierarchyResourcesIndexResult.TotalAzureResources ?? 0) +
                ($keyVaultsResourcesIndexResult.TotalAzureResources ?? 0) +
                ($virtualMachinesResourcesIndexResult.TotalAzureResources ?? 0) +
                ($automationAccountsResourcesIndexResult.TotalAzureResources ?? 0) +
                ($functionAppsResourcesIndexResult.TotalAzureResources ?? 0) +
                ($logicAppsResourcesIndexResult.TotalAzureResources ?? 0) +
                ($webAppsResourcesIndexResult.TotalAzureResources ?? 0)
            )
            TotalAzureRelationshipsIndexed = (
                ($azureHierarchyRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($keyVaultsRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($virtualMachinesRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($automationAccountsRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($functionAppsRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($logicAppsRelationshipsIndexResult.TotalAzureRelationships ?? 0) +
                ($webAppsRelationshipsIndexResult.TotalAzureRelationships ?? 0)
            )
        }
    }

    Write-Verbose "Orchestration complete successfully"
    Write-Verbose "Principals: $($finalResult.Summary.TotalPrincipalsIndexed) indexed"
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

