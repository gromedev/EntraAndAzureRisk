
#region Durable Functions Orchestrator - V2 UNIFIED ARCHITECTURE (8 Collectors)
<#
.SYNOPSIS
    Orchestrates comprehensive Entra data collection with delta change detection
.DESCRIPTION
    V2 Architecture: Unified Containers with Type Discriminators

    8 Collectors → 4 Indexers → 7 Containers

    Phase 1: Principal Collection (Parallel - 5 collectors)
      - CollectUsersWithAuthMethods → users.jsonl (principalType=user)
      - CollectEntraGroups → groups.jsonl (principalType=group)
      - CollectEntraServicePrincipals → serviceprincipals.jsonl (principalType=servicePrincipal)
      - CollectDevices → devices.jsonl (principalType=device)
      - CollectAppRegistrations → applications.jsonl (principalType=application)

    Phase 2: Relationship, Policy, and Event Collection (Parallel - 3 collectors)
      - CollectRelationships → relationships.jsonl (all relationType: groupMember, directoryRole, pimEligible, pimActive, pimGroupEligible, pimGroupActive, azureRbac)
      - CollectPolicies → policies.jsonl (all policyType: conditionalAccess, roleManagement, roleManagementAssignment)
      - CollectEvents → events.jsonl (all eventType: signIn, audit)

    Phase 3: Unified Indexing (4 indexers)
      - IndexPrincipalsInCosmosDB → principals container
      - IndexRelationshipsInCosmosDB → relationships container
      - IndexPoliciesInCosmosDB → policies container
      - IndexEventsInCosmosDB → events container

    Phase 4: TestAIFoundry - Optional connectivity test

    V2 Benefits:
    - 8 collectors instead of 13+ (simplified)
    - Unified containers reduce Cosmos complexity (28 → 7 containers)
    - Type discriminators enable filtering (principalType, relationType, policyType, eventType)
    - Denormalized relationship data for Power BI (no joins needed)
    - Preserved delta detection pattern (~99% write reduction)
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration (V2 - 8 Collectors)"
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

    #region Wait for All Collections
    Write-Verbose "Waiting for all 8 collectors to complete..."

    $allResults = Wait-ActivityFunction -Task @(
        $usersTask,
        $groupsTask,
        $servicePrincipalsTask,
        $devicesTask,
        $applicationsTask,
        $relationshipsTask,
        $policiesTask,
        $eventsTask
    )

    $usersResult = $allResults[0]
    $groupsResult = $allResults[1]
    $servicePrincipalsResult = $allResults[2]
    $devicesResult = $allResults[3]
    $applicationsResult = $allResults[4]
    $relationshipsResult = $allResults[5]
    $policiesResult = $allResults[6]
    $eventsResult = $allResults[7]
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

    Write-Verbose "Collection complete:"
    Write-Verbose "  Users: $($usersResult.UserCount ?? 0)"
    Write-Verbose "  Groups: $($groupsResult.GroupCount ?? 0)"
    Write-Verbose "  Service Principals: $($servicePrincipalsResult.ServicePrincipalCount ?? 0)"
    Write-Verbose "  Devices: $($devicesResult.DeviceCount ?? 0)"
    Write-Verbose "  Applications: $($applicationsResult.AppRegistrationCount ?? 0)"
    Write-Verbose "  Relationships: $($relationshipsResult.RelationshipCount ?? 0)"
    Write-Verbose "  Policies: $($policiesResult.PolicyCount ?? 0)"
    Write-Verbose "  Events: $($eventsResult.EventCount ?? 0)"
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
        Architecture = 'V2-8Collectors'

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
            AllCollectionsSucceeded = (
                $usersResult.Success -and
                $groupsResult.Success -and
                $servicePrincipalsResult.Success -and
                $devicesResult.Success -and
                $applicationsResult.Success -and
                $relationshipsResult.Success -and
                $policiesResult.Success -and
                $eventsResult.Success
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

