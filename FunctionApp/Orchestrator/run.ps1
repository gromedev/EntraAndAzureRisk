
#region Durable Functions Orchestrator - V3.5 UNIFIED ARCHITECTURE
<#
.SYNOPSIS
    Orchestrates comprehensive Entra and Azure data collection with unified containers
.DESCRIPTION
    V3.5 Architecture: Unified Containers with Semantic Correctness + Graph Support + Abuse Edges

    6 Containers:
    - principals (users, groups, servicePrincipals, devices) - partition: /principalType
    - resources (applications, Azure resources, role definitions) - partition: /resourceType
    - edges (all relationships unified + derived abuse edges) - partition: /edgeType
    - policies - partition: /policyType
    - events - partition: /eventDate
    - audit (changes + snapshots) - partition: /auditDate

    Phase 1: All Entity Collection (Parallel - 17 collectors)
      Principal Collectors (4):
      - CollectUsersWithAuthMethods -> principals.jsonl (principalType=user)
      - CollectEntraGroups -> principals.jsonl (principalType=group)
      - CollectEntraServicePrincipals -> principals.jsonl (principalType=servicePrincipal)
      - CollectDevices -> principals.jsonl (principalType=device)

      Resource Collectors (10):
      - CollectAppRegistrations -> resources.jsonl (resourceType=application)
      - CollectAzureHierarchy -> resources.jsonl (resourceType=tenant/managementGroup/subscription/resourceGroup)
      - CollectKeyVaults -> resources.jsonl (resourceType=keyVault)
      - CollectVirtualMachines -> resources.jsonl (resourceType=virtualMachine)
      - CollectAutomationAccounts -> resources.jsonl (resourceType=automationAccount)
      - CollectFunctionApps -> resources.jsonl (resourceType=functionApp)
      - CollectLogicApps -> resources.jsonl (resourceType=logicApp)
      - CollectWebApps -> resources.jsonl (resourceType=webApp)
      - CollectDirectoryRoleDefinitions -> resources.jsonl (resourceType=directoryRoleDefinition)
      - CollectAzureRoleDefinitions -> resources.jsonl (resourceType=azureRoleDefinition)

      Policy/Event Collectors (2):
      - CollectPolicies -> policies.jsonl
      - CollectEvents -> events.jsonl

    Phase 2: Unified Edge Collection
      - CollectRelationships -> edges.jsonl (all 24+ edgeTypes)
        Includes: caPolicyTargetsPrincipal, caPolicyExcludesPrincipal,
                  caPolicyTargetsApplication, caPolicyExcludesApplication,
                  caPolicyUsesLocation, rolePolicyAssignment

    Phase 3: Unified Indexing (5 indexers)
      - IndexPrincipalsInCosmosDB -> principals container
      - IndexResourcesInCosmosDB -> resources container
      - IndexEdgesInCosmosDB -> edges container
      - IndexPoliciesInCosmosDB -> policies container
      - IndexEventsInCosmosDB -> events container

    Phase 4: Derive Abuse Edges (V3.5)
      - DeriveAbuseEdges -> edges container (derived abuse capabilities)
        Derives from: appRoleAssignment, directoryRole, appOwner, spOwner, groupOwner
        Creates: canAddSecretToAnyApp, isGlobalAdmin, canAssignAnyRole, canAddSecret, etc.
        "The core BloodHound value" - converting raw permissions to attack paths

    V3.5 Benefits:
    - Semantic correctness (applications are resources, not principals)
    - Unified edge container enables Gremlin graph projection
    - Temporal fields (effectiveFrom/effectiveTo) for historical queries
    - Simplified container structure (9 -> 6 containers)
    - edgeType discriminator for all relationships
    - Role definitions as synthetic vertices for complete graph
    - CA policy edges for MFA gap analysis
    - Role management policy edges for PIM activation risk analysis
    - Derived abuse edges for attack path analysis (V3.5)
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration (V3 - Unified Architecture)"
    Write-Verbose "Instance ID: $($Context.InstanceId)"

    # Single Get-Date call to prevent race condition
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Verbose "Collection timestamp: $timestampFormatted"

    $collectionInput = @{
        Timestamp = $timestamp
    }

    #region Phase 1: Entity Collection (Parallel - 14 collectors)
    Write-Verbose "Phase 1: Collecting all entities in parallel (14 collectors)..."

    # Principal Collectors (4) - output to principals.jsonl
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

    # Resource Collectors (8) - output to resources.jsonl
    $applicationsTask = Invoke-DurableActivity `
        -FunctionName 'CollectAppRegistrations' `
        -Input $collectionInput `
        -NoWait

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

    # V3.1: Role Definition Collectors (2) - synthetic vertices
    $directoryRoleDefsTask = Invoke-DurableActivity `
        -FunctionName 'CollectDirectoryRoleDefinitions' `
        -Input $collectionInput `
        -NoWait

    $azureRoleDefsTask = Invoke-DurableActivity `
        -FunctionName 'CollectAzureRoleDefinitions' `
        -Input $collectionInput `
        -NoWait

    # Policy and Event Collectors (2)
    $policiesTask = Invoke-DurableActivity `
        -FunctionName 'CollectPolicies' `
        -Input $collectionInput `
        -NoWait

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
    Write-Verbose "Waiting for all 17 collectors to complete..."

    $allResults = Wait-ActivityFunction -Task @(
        $usersTask,
        $groupsTask,
        $servicePrincipalsTask,
        $devicesTask,
        $applicationsTask,
        $azureHierarchyTask,
        $keyVaultsTask,
        $virtualMachinesTask,
        $automationAccountsTask,
        $functionAppsTask,
        $logicAppsTask,
        $webAppsTask,
        $directoryRoleDefsTask,
        $azureRoleDefsTask,
        $policiesTask,
        $eventsTask,
        $edgesTask
    )

    # Unpack results
    $usersResult = $allResults[0]
    $groupsResult = $allResults[1]
    $servicePrincipalsResult = $allResults[2]
    $devicesResult = $allResults[3]
    $applicationsResult = $allResults[4]
    $azureHierarchyResult = $allResults[5]
    $keyVaultsResult = $allResults[6]
    $virtualMachinesResult = $allResults[7]
    $automationAccountsResult = $allResults[8]
    $functionAppsResult = $allResults[9]
    $logicAppsResult = $allResults[10]
    $webAppsResult = $allResults[11]
    $directoryRoleDefsResult = $allResults[12]
    $azureRoleDefsResult = $allResults[13]
    $policiesResult = $allResults[14]
    $eventsResult = $allResults[15]
    $edgesResult = $allResults[16]
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

    if (-not $keyVaultsResult.Success) {
        Write-Warning "Key Vaults collection failed: $($keyVaultsResult.Error)"
        $keyVaultsResult = @{ Success = $false; KeyVaultCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    if (-not $virtualMachinesResult.Success) {
        Write-Warning "Virtual Machines collection failed: $($virtualMachinesResult.Error)"
        $virtualMachinesResult = @{ Success = $false; VirtualMachineCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    if (-not $automationAccountsResult.Success) {
        Write-Warning "Automation Accounts collection failed: $($automationAccountsResult.Error)"
        $automationAccountsResult = @{ Success = $false; AutomationAccountCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    if (-not $functionAppsResult.Success) {
        Write-Warning "Function Apps collection failed: $($functionAppsResult.Error)"
        $functionAppsResult = @{ Success = $false; FunctionAppCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    if (-not $logicAppsResult.Success) {
        Write-Warning "Logic Apps collection failed: $($logicAppsResult.Error)"
        $logicAppsResult = @{ Success = $false; LogicAppCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    if (-not $webAppsResult.Success) {
        Write-Warning "Web Apps collection failed: $($webAppsResult.Error)"
        $webAppsResult = @{ Success = $false; WebAppCount = 0; ResourcesBlobName = $null; EdgesBlobName = $null }
    }

    # V3.1: Role definition collectors (non-critical)
    if (-not $directoryRoleDefsResult.Success) {
        Write-Warning "Directory Role Definitions collection failed: $($directoryRoleDefsResult.Error)"
        $directoryRoleDefsResult = @{ Success = $false; RoleDefinitionCount = 0; ResourcesBlobName = $null }
    }

    if (-not $azureRoleDefsResult.Success) {
        Write-Warning "Azure Role Definitions collection failed: $($azureRoleDefsResult.Error)"
        $azureRoleDefsResult = @{ Success = $false; RoleDefinitionCount = 0; ResourcesBlobName = $null }
    }

    if (-not $policiesResult.Success) {
        Write-Warning "Policies collection failed: $($policiesResult.Error)"
        $policiesResult = @{ Success = $false; PolicyCount = 0; BlobName = $null }
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
    Write-Verbose "  Users: $($usersResult.UserCount ?? 0)"
    Write-Verbose "  Groups: $($groupsResult.GroupCount ?? 0)"
    Write-Verbose "  Service Principals: $($servicePrincipalsResult.ServicePrincipalCount ?? 0)"
    Write-Verbose "  Devices: $($devicesResult.DeviceCount ?? 0)"
    Write-Verbose "  Applications: $($applicationsResult.AppCount ?? 0)"
    Write-Verbose "  Azure Hierarchy: $($azureHierarchyResult.ResourceCount ?? 0)"
    Write-Verbose "  Key Vaults: $($keyVaultsResult.KeyVaultCount ?? 0)"
    Write-Verbose "  Virtual Machines: $($virtualMachinesResult.VirtualMachineCount ?? 0)"
    Write-Verbose "  Automation Accounts: $($automationAccountsResult.AutomationAccountCount ?? 0)"
    Write-Verbose "  Function Apps: $($functionAppsResult.FunctionAppCount ?? 0)"
    Write-Verbose "  Logic Apps: $($logicAppsResult.LogicAppCount ?? 0)"
    Write-Verbose "  Web Apps: $($webAppsResult.WebAppCount ?? 0)"
    Write-Verbose "  Policies: $($policiesResult.PolicyCount ?? 0)"
    Write-Verbose "  Events: $($eventsResult.EventCount ?? 0)"
    Write-Verbose "  Edges: $($edgesResult.EdgeCount ?? 0)"
    Write-Verbose "  Directory Role Definitions: $($directoryRoleDefsResult.RoleDefinitionCount ?? 0)"
    Write-Verbose "  Azure Role Definitions: $($azureRoleDefsResult.RoleDefinitionCount ?? 0)"
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

    # Index Resources (unified: applications + all Azure resources)
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

    # Index Azure resources (hierarchy, key vaults, VMs, etc.)
    $azureResourceCollectors = @(
        @{ Result = $azureHierarchyResult; Name = 'AzureHierarchy' },
        @{ Result = $keyVaultsResult; Name = 'KeyVaults' },
        @{ Result = $virtualMachinesResult; Name = 'VirtualMachines' },
        @{ Result = $automationAccountsResult; Name = 'AutomationAccounts' },
        @{ Result = $functionAppsResult; Name = 'FunctionApps' },
        @{ Result = $logicAppsResult; Name = 'LogicApps' },
        @{ Result = $webAppsResult; Name = 'WebApps' },
        @{ Result = $directoryRoleDefsResult; Name = 'DirectoryRoleDefinitions' },
        @{ Result = $azureRoleDefsResult; Name = 'AzureRoleDefinitions' }
    )

    foreach ($collector in $azureResourceCollectors) {
        if ($collector.Result.Success -and $collector.Result.ResourcesBlobName) {
            $indexInput = @{ Timestamp = $timestamp; BlobName = $collector.Result.ResourcesBlobName }
            $indexResult = Invoke-DurableActivity -FunctionName 'IndexResourcesInCosmosDB' -Input $indexInput
            if ($indexResult.Success) {
                Write-Verbose "$($collector.Name) resources indexing complete: $($indexResult.TotalResources) total"
                $resourcesIndexResult.TotalResources += $indexResult.TotalResources
                $resourcesIndexResult.NewResources += $indexResult.NewResources
                $resourcesIndexResult.ModifiedResources += $indexResult.ModifiedResources
                $resourcesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
            } else {
                Write-Warning "$($collector.Name) resources indexing failed: $($indexResult.Error)"
            }
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

    # Also index Azure relationship edges from each collector
    foreach ($collector in $azureResourceCollectors) {
        if ($collector.Result.Success -and $collector.Result.EdgesBlobName) {
            $indexInput = @{ Timestamp = $timestamp; BlobName = $collector.Result.EdgesBlobName }
            $indexResult = Invoke-DurableActivity -FunctionName 'IndexEdgesInCosmosDB' -Input $indexInput
            if ($indexResult.Success) {
                Write-Verbose "$($collector.Name) edges indexing complete: $($indexResult.TotalEdges) total"
                $edgesIndexResult.TotalEdges += $indexResult.TotalEdges
                $edgesIndexResult.NewEdges += $indexResult.NewEdges
                $edgesIndexResult.ModifiedEdges += $indexResult.ModifiedEdges
                $edgesIndexResult.CosmosWriteCount += $indexResult.CosmosWriteCount
            } else {
                Write-Warning "$($collector.Name) edges indexing failed: $($indexResult.Error)"
            }
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
    #endregion

    #region Phase 4: Derive Abuse Edges (V3.5)
    Write-Verbose "Phase 4: Deriving abuse capability edges from permissions and roles..."

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
    #endregion

    #region Build Final Result
    $finalResult = @{
        OrchestrationId = $Context.InstanceId
        Timestamp = $timestampFormatted
        Status = 'Completed'
        Architecture = 'V3-UnifiedContainers'

        Collection = @{
            # Principals
            Users = @{
                Success = $usersResult.Success
                Count = $usersResult.UserCount ?? 0
                BlobPath = $usersResult.PrincipalsBlobName
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
            KeyVaults = @{
                Success = $keyVaultsResult.Success
                Count = $keyVaultsResult.KeyVaultCount ?? 0
                ResourcesBlobPath = $keyVaultsResult.ResourcesBlobName
                EdgesBlobPath = $keyVaultsResult.EdgesBlobName
            }
            VirtualMachines = @{
                Success = $virtualMachinesResult.Success
                Count = $virtualMachinesResult.VirtualMachineCount ?? 0
                ResourcesBlobPath = $virtualMachinesResult.ResourcesBlobName
                EdgesBlobPath = $virtualMachinesResult.EdgesBlobName
            }
            AutomationAccounts = @{
                Success = $automationAccountsResult.Success
                Count = $automationAccountsResult.AutomationAccountCount ?? 0
                ResourcesBlobPath = $automationAccountsResult.ResourcesBlobName
                EdgesBlobPath = $automationAccountsResult.EdgesBlobName
            }
            FunctionApps = @{
                Success = $functionAppsResult.Success
                Count = $functionAppsResult.FunctionAppCount ?? 0
                ResourcesBlobPath = $functionAppsResult.ResourcesBlobName
                EdgesBlobPath = $functionAppsResult.EdgesBlobName
            }
            LogicApps = @{
                Success = $logicAppsResult.Success
                Count = $logicAppsResult.LogicAppCount ?? 0
                ResourcesBlobPath = $logicAppsResult.ResourcesBlobName
                EdgesBlobPath = $logicAppsResult.EdgesBlobName
            }
            WebApps = @{
                Success = $webAppsResult.Success
                Count = $webAppsResult.WebAppCount ?? 0
                ResourcesBlobPath = $webAppsResult.ResourcesBlobName
                EdgesBlobPath = $webAppsResult.EdgesBlobName
            }

            # V3.1: Role Definitions (synthetic vertices)
            DirectoryRoleDefinitions = @{
                Success = $directoryRoleDefsResult.Success
                Count = $directoryRoleDefsResult.RoleDefinitionCount ?? 0
                ResourcesBlobPath = $directoryRoleDefsResult.ResourcesBlobName
                Summary = $directoryRoleDefsResult.Summary
            }
            AzureRoleDefinitions = @{
                Success = $azureRoleDefsResult.Success
                Count = $azureRoleDefsResult.RoleDefinitionCount ?? 0
                ResourcesBlobPath = $azureRoleDefsResult.ResourcesBlobName
                Summary = $azureRoleDefsResult.Summary
            }

            # Edges, Policies, Events
            Edges = @{
                Success = $edgesResult.Success
                Count = $edgesResult.EdgeCount ?? 0
                BlobPath = $edgesResult.EdgesBlobName
                Summary = $edgesResult.Summary
            }
            # V3.5: Derived Abuse Edges
            AbuseEdges = @{
                Success = $abuseEdgesResult.Success
                Count = $abuseEdgesResult.DerivedEdgeCount ?? 0
                Statistics = $abuseEdgesResult.Statistics
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
            TotalKeyVaults = $keyVaultsResult.KeyVaultCount ?? 0
            TotalVirtualMachines = $virtualMachinesResult.VirtualMachineCount ?? 0
            TotalAutomationAccounts = $automationAccountsResult.AutomationAccountCount ?? 0
            TotalFunctionApps = $functionAppsResult.FunctionAppCount ?? 0
            TotalLogicApps = $logicAppsResult.LogicAppCount ?? 0
            TotalWebApps = $webAppsResult.WebAppCount ?? 0
            TotalDirectoryRoleDefinitions = $directoryRoleDefsResult.RoleDefinitionCount ?? 0
            TotalAzureRoleDefinitions = $azureRoleDefsResult.RoleDefinitionCount ?? 0
            TotalResources = (
                ($applicationsResult.AppCount ?? 0) +
                ($azureHierarchyResult.ResourceCount ?? 0) +
                ($keyVaultsResult.KeyVaultCount ?? 0) +
                ($virtualMachinesResult.VirtualMachineCount ?? 0) +
                ($automationAccountsResult.AutomationAccountCount ?? 0) +
                ($functionAppsResult.FunctionAppCount ?? 0) +
                ($logicAppsResult.LogicAppCount ?? 0) +
                ($webAppsResult.WebAppCount ?? 0) +
                ($directoryRoleDefsResult.RoleDefinitionCount ?? 0) +
                ($azureRoleDefsResult.RoleDefinitionCount ?? 0)
            )

            # Other counts
            TotalEdges = $edgesResult.EdgeCount ?? 0
            TotalAbuseEdges = $abuseEdgesResult.DerivedEdgeCount ?? 0
            TotalPolicies = $policiesResult.PolicyCount ?? 0
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
                $keyVaultsResult.Success -and
                $virtualMachinesResult.Success -and
                $automationAccountsResult.Success -and
                $functionAppsResult.Success -and
                $logicAppsResult.Success -and
                $webAppsResult.Success -and
                $directoryRoleDefsResult.Success -and
                $azureRoleDefsResult.Success
            )
            AllIndexingSucceeded = (
                $principalsIndexResult.Success -and
                $resourcesIndexResult.Success -and
                $edgesIndexResult.Success -and
                $policiesIndexResult.Success -and
                $eventsIndexResult.Success
            )
        }
    }

    Write-Verbose "Orchestration complete successfully"
    Write-Verbose "Principals: $($finalResult.Summary.TotalPrincipals) indexed"
    Write-Verbose "Resources: $($finalResult.Summary.TotalResources) indexed"
    Write-Verbose "Edges: $($finalResult.Summary.TotalEdges) indexed"
    Write-Verbose "Abuse Edges: $($finalResult.Summary.TotalAbuseEdges) derived (V3.5)"
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

