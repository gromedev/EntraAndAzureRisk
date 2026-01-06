
#region Durable Functions Orchestrator - EXPANDED DATA COLLECTION
<#
.SYNOPSIS
    Orchestrates comprehensive Entra data collection with delta change detection
.DESCRIPTION
    Workflow:
    Phase 1: Entity Collection (Parallel)
      - CollectEntraUsers, CollectEntraGroups, CollectEntraServicePrincipals (existing)
      - CollectRiskyUsers, CollectDevices, CollectConditionalAccessPolicies (new)
      - CollectAppRegistrations, CollectDirectoryRoles (new)

    Phase 2: N+1 Collection (After Users)
      - CollectUserAuthMethods (requires user list)

    Phase 3: Event Collection (Parallel, time-windowed)
      - CollectSignInLogs (failed/risky only)
      - CollectDirectoryAudits

    Phase 4: Entity Indexing (Parallel with retry)
      - All entity indexers

    Phase 5: Event Indexing (Parallel)
      - SignInLogs, DirectoryAudits (append-only)

    Phase 6: TestAIFoundry - Optional connectivity test

    Benefits of this flow:
    - Fast parallel collection (streaming to Blob)
    - Decoupled indexing (can retry independently)
    - Delta detection reduces Cosmos writes
    - Blob acts as checkpoint/buffer
    - Comprehensive security data coverage

    Partial Success Pattern:
    - CollectEntraUsers fails → STOP (critical, no data)
    - Other collections fail → CONTINUE (partial data still indexed)
    - Indexing fails → CONTINUE (data safe in Blob, can retry)
    - TestAIFoundry fails → CONTINUE (optional feature)
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration"
    Write-Verbose "Instance ID: $($Context.InstanceId)"
    
    # Single Get-Date call to prevent race condition
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    Write-Verbose "Collection timestamp: $timestampFormatted"
    
    #region Step 1: Collect All Entity Data (Parallel)
    Write-Verbose "Step 1: Collecting entity data from Entra ID in parallel..."
    Write-Verbose "  - Users, Groups, Service Principals (existing)"
    Write-Verbose "  - Risky Users, Devices, CA Policies, App Registrations, Directory Roles (new)"

    $collectionInput = @{
        Timestamp = $timestamp
    }

    # Start all entity collections in parallel
    $userCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraUsers' `
        -Input $collectionInput `
        -NoWait

    $groupCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraGroups' `
        -Input $collectionInput `
        -NoWait

    $spCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraServicePrincipals' `
        -Input $collectionInput `
        -NoWait

    # New entity collections
    $riskyUsersCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectRiskyUsers' `
        -Input $collectionInput `
        -NoWait

    $devicesCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectDevices' `
        -Input $collectionInput `
        -NoWait

    $caPoliciesCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectConditionalAccessPolicies' `
        -Input $collectionInput `
        -NoWait

    $appRegsCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectAppRegistrations' `
        -Input $collectionInput `
        -NoWait

    $directoryRolesCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectDirectoryRoles' `
        -Input $collectionInput `
        -NoWait

    # Wait for all entity collections to complete
    $collectionResults = Wait-ActivityFunction -Task @(
        $userCollectionTask,
        $groupCollectionTask,
        $spCollectionTask,
        $riskyUsersCollectionTask,
        $devicesCollectionTask,
        $caPoliciesCollectionTask,
        $appRegsCollectionTask,
        $directoryRolesCollectionTask
    )

    $collectionResult = $collectionResults[0]           # Users
    $groupCollectionResult = $collectionResults[1]      # Groups
    $spCollectionResult = $collectionResults[2]         # Service Principals
    $riskyUsersResult = $collectionResults[3]           # Risky Users
    $devicesResult = $collectionResults[4]              # Devices
    $caPoliciesResult = $collectionResults[5]           # CA Policies
    $appRegsResult = $collectionResults[6]              # App Registrations
    $directoryRolesResult = $collectionResults[7]       # Directory Roles

    # Validate users succeeded (fail fast on users, warn on groups/SPs)
    if (-not $collectionResult.Success) {
        throw "User collection failed: $($collectionResult.Error)"
    }

    if (-not $groupCollectionResult.Success) {
        Write-Warning "Group collection failed: $($groupCollectionResult.Error)"
        # Continue even if groups failed
        # Set default values for failed group collection
        $groupCollectionResult = @{
            Success = $false
            GroupCount = 0
            BlobName = $null
            Summary = @{
                totalCount = 0
                securityEnabledCount = 0
                mailEnabledCount = 0
                m365GroupCount = 0
                roleAssignableCount = 0
                cloudOnlyCount = 0
                syncedCount = 0
            }
        }
    }

    if (-not $spCollectionResult.Success) {
        Write-Warning "Service Principal collection failed: $($spCollectionResult.Error)"
        # Continue even if service principals failed
        # Set default values for failed SP collection
        $spCollectionResult = @{
            Success = $false
            ServicePrincipalCount = 0
            BlobName = $null
            Summary = @{
                totalCount = 0
                accountEnabledCount = 0
                accountDisabledCount = 0
                applicationTypeCount = 0
                managedIdentityTypeCount = 0
                legacyTypeCount = 0
                socialIdpTypeCount = 0
            }
        }
    }

    # Validate new entity collections (non-critical - continue on failure)
    if (-not $riskyUsersResult.Success) {
        Write-Warning "Risky Users collection failed: $($riskyUsersResult.Error)"
        $riskyUsersResult = @{ Success = $false; RiskyUserCount = 0; BlobName = $null }
    }

    if (-not $devicesResult.Success) {
        Write-Warning "Devices collection failed: $($devicesResult.Error)"
        $devicesResult = @{ Success = $false; DeviceCount = 0; BlobName = $null }
    }

    if (-not $caPoliciesResult.Success) {
        Write-Warning "Conditional Access Policies collection failed: $($caPoliciesResult.Error)"
        $caPoliciesResult = @{ Success = $false; PolicyCount = 0; BlobName = $null }
    }

    if (-not $appRegsResult.Success) {
        Write-Warning "App Registrations collection failed: $($appRegsResult.Error)"
        $appRegsResult = @{ Success = $false; AppRegistrationCount = 0; BlobName = $null }
    }

    if (-not $directoryRolesResult.Success) {
        Write-Warning "Directory Roles collection failed: $($directoryRolesResult.Error)"
        $directoryRolesResult = @{ Success = $false; RoleCount = 0; BlobName = $null }
    }

    Write-Verbose "Entity Collection complete:"
    Write-Verbose "  Users: $($collectionResult.UserCount) users"
    Write-Verbose "  Groups: $($groupCollectionResult.GroupCount) groups"
    Write-Verbose "  Service Principals: $($spCollectionResult.ServicePrincipalCount) service principals"
    Write-Verbose "  Risky Users: $($riskyUsersResult.RiskyUserCount) risky users"
    Write-Verbose "  Devices: $($devicesResult.DeviceCount) devices"
    Write-Verbose "  CA Policies: $($caPoliciesResult.PolicyCount) policies"
    Write-Verbose "  App Registrations: $($appRegsResult.AppRegistrationCount) apps"
    Write-Verbose "  Directory Roles: $($directoryRolesResult.RoleCount) roles"
    #endregion

    #region Step 2: Collect User Auth Methods (N+1 Pattern - Requires Users)
    Write-Verbose "Step 2: Collecting user authentication methods (N+1 pattern)..."

    $authMethodsResult = @{ Success = $false; UserCount = 0; BlobName = $null }

    if ($collectionResult.Success -and $collectionResult.BlobName) {
        $authMethodsInput = @{
            Timestamp = $timestamp
            UsersBlobName = $collectionResult.BlobName
        }

        $authMethodsResult = Invoke-DurableActivity `
            -FunctionName 'CollectUserAuthMethods' `
            -Input $authMethodsInput

        if ($authMethodsResult.Success) {
            Write-Verbose "Auth Methods collection complete: $($authMethodsResult.UserCount) users processed"
        }
        else {
            Write-Warning "Auth Methods collection failed: $($authMethodsResult.Error)"
            $authMethodsResult = @{ Success = $false; UserCount = 0; BlobName = $null }
        }
    }
    else {
        Write-Verbose "Skipping Auth Methods collection (user collection required)"
    }
    #endregion

    #region Step 3: Collect Event Data (Parallel, Time-Windowed)
    Write-Verbose "Step 3: Collecting event data (Sign-In Logs, Directory Audits)..."

    # Start event collections in parallel
    $signInLogsTask = Invoke-DurableActivity `
        -FunctionName 'CollectSignInLogs' `
        -Input $collectionInput `
        -NoWait

    $directoryAuditsTask = Invoke-DurableActivity `
        -FunctionName 'CollectDirectoryAudits' `
        -Input $collectionInput `
        -NoWait

    # Wait for event collections
    $eventResults = Wait-ActivityFunction -Task @($signInLogsTask, $directoryAuditsTask)
    $signInLogsResult = $eventResults[0]
    $directoryAuditsResult = $eventResults[1]

    # Validate event collections (non-critical)
    if (-not $signInLogsResult.Success) {
        Write-Warning "Sign-In Logs collection failed: $($signInLogsResult.Error)"
        $signInLogsResult = @{ Success = $false; SignInCount = 0; BlobName = $null }
    }
    else {
        Write-Verbose "Sign-In Logs collection complete: $($signInLogsResult.SignInCount) events"
    }

    if (-not $directoryAuditsResult.Success) {
        Write-Warning "Directory Audits collection failed: $($directoryAuditsResult.Error)"
        $directoryAuditsResult = @{ Success = $false; AuditCount = 0; BlobName = $null }
    }
    else {
        Write-Verbose "Directory Audits collection complete: $($directoryAuditsResult.AuditCount) events"
    }
    #endregion
    
    #region Step 4: Index All Entity Data in Cosmos DB (with Retry)
    Write-Verbose "Step 4: Indexing all entity data in Cosmos DB with delta detection..."

    $maxRetries = 3

    # Index users with retry logic
    $retryCount = 0
    $indexSuccess = $false

    while ($retryCount -lt $maxRetries -and -not $indexSuccess) {
        $indexInput = @{
            Timestamp = $timestamp
            UserCount = $collectionResult.UserCount
            BlobName = $collectionResult.BlobName
            Summary = $collectionResult.Summary
            CosmosDocumentId = $timestamp
        }

        $indexResult = Invoke-DurableActivity `
            -FunctionName 'IndexInCosmosDB' `
            -Input $indexInput

        if ($indexResult -and $indexResult.Success) {
            $indexSuccess = $true
            Write-Verbose "User indexing complete:"
            Write-Verbose "  Total users: $($indexResult.TotalUsers)"
            Write-Verbose "  New: $($indexResult.NewUsers)"
            Write-Verbose "  Modified: $($indexResult.ModifiedUsers)"
            Write-Verbose "  Deleted: $($indexResult.DeletedUsers)"
            Write-Verbose "  Unchanged: $($indexResult.UnchangedUsers)"
            Write-Verbose "  Cosmos writes: $($indexResult.CosmosWriteCount)"
        }
        else {
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                Write-Warning "User indexing failed (attempt $retryCount/$maxRetries). Retrying in 60s..."
                Start-DurableTimer -Duration (New-TimeSpan -Seconds 60)
            }
            else {
                Write-Error "User indexing failed after $maxRetries attempts"
                # Blob preserved for manual recovery
            }
        }
    }

    # Index groups with retry logic (only if collection succeeded)
    $groupIndexSuccess = $false

    if ($groupCollectionResult.Success) {
        $groupRetryCount = 0

        while ($groupRetryCount -lt $maxRetries -and -not $groupIndexSuccess) {
            $groupIndexInput = @{
                Timestamp = $timestamp
                GroupCount = $groupCollectionResult.GroupCount
                BlobName = $groupCollectionResult.BlobName
                Summary = $groupCollectionResult.Summary
                CosmosDocumentId = $timestamp
            }

            $groupIndexResult = Invoke-DurableActivity `
                -FunctionName 'IndexGroupsInCosmosDB' `
                -Input $groupIndexInput

            if ($groupIndexResult -and $groupIndexResult.Success) {
                $groupIndexSuccess = $true
                Write-Verbose "Group indexing complete:"
                Write-Verbose "  Total groups: $($groupIndexResult.TotalGroups)"
                Write-Verbose "  New: $($groupIndexResult.NewGroups)"
                Write-Verbose "  Modified: $($groupIndexResult.ModifiedGroups)"
                Write-Verbose "  Deleted: $($groupIndexResult.DeletedGroups)"
                Write-Verbose "  Unchanged: $($groupIndexResult.UnchangedGroups)"
                Write-Verbose "  Cosmos writes: $($groupIndexResult.CosmosWriteCount)"
            }
            else {
                $groupRetryCount++
                if ($groupRetryCount -lt $maxRetries) {
                    Write-Warning "Group indexing failed (attempt $groupRetryCount/$maxRetries). Retrying in 60s..."
                    Start-DurableTimer -Duration (New-TimeSpan -Seconds 60)
                }
                else {
                    Write-Error "Group indexing failed after $maxRetries attempts"
                    # Blob preserved for manual recovery
                }
            }
        }
    }
    else {
        Write-Verbose "Skipping group indexing (collection failed)"
        # Set default values for skipped group indexing
        $groupIndexResult = @{
            Success = $false
            TotalGroups = 0
            NewGroups = 0
            ModifiedGroups = 0
            DeletedGroups = 0
            UnchangedGroups = 0
            CosmosWriteCount = 0
        }
    }

    # Index service principals with retry logic (only if collection succeeded)
    $spIndexSuccess = $false

    if ($spCollectionResult.Success) {
        $spRetryCount = 0

        while ($spRetryCount -lt $maxRetries -and -not $spIndexSuccess) {
            $spIndexInput = @{
                Timestamp = $timestamp
                ServicePrincipalCount = $spCollectionResult.ServicePrincipalCount
                BlobName = $spCollectionResult.BlobName
                Summary = $spCollectionResult.Summary
                CosmosDocumentId = $timestamp
            }

            $spIndexResult = Invoke-DurableActivity `
                -FunctionName 'IndexServicePrincipalsInCosmosDB' `
                -Input $spIndexInput

            if ($spIndexResult -and $spIndexResult.Success) {
                $spIndexSuccess = $true
                Write-Verbose "Service Principal indexing complete:"
                Write-Verbose "  Total service principals: $($spIndexResult.TotalServicePrincipals)"
                Write-Verbose "  New: $($spIndexResult.NewServicePrincipals)"
                Write-Verbose "  Modified: $($spIndexResult.ModifiedServicePrincipals)"
                Write-Verbose "  Deleted: $($spIndexResult.DeletedServicePrincipals)"
                Write-Verbose "  Unchanged: $($spIndexResult.UnchangedServicePrincipals)"
                Write-Verbose "  Cosmos writes: $($spIndexResult.CosmosWriteCount)"
            }
            else {
                $spRetryCount++
                if ($spRetryCount -lt $maxRetries) {
                    Write-Warning "Service Principal indexing failed (attempt $spRetryCount/$maxRetries). Retrying in 60s..."
                    Start-DurableTimer -Duration (New-TimeSpan -Seconds 60)
                }
                else {
                    Write-Error "Service Principal indexing failed after $maxRetries attempts"
                    # Blob preserved for manual recovery
                }
            }
        }
    }
    else {
        Write-Verbose "Skipping service principal indexing (collection failed)"
        # Set default values for skipped SP indexing
        $spIndexResult = @{
            Success = $false
            TotalServicePrincipals = 0
            NewServicePrincipals = 0
            ModifiedServicePrincipals = 0
            DeletedServicePrincipals = 0
            UnchangedServicePrincipals = 0
            CosmosWriteCount = 0
        }
    }

    # Index Risky Users (simplified - single attempt, non-critical)
    $riskyUsersIndexResult = @{ Success = $false; TotalRiskyUsers = 0; NewRiskyUsers = 0; ModifiedRiskyUsers = 0; DeletedRiskyUsers = 0; UnchangedRiskyUsers = 0; CosmosWriteCount = 0 }
    if ($riskyUsersResult.Success -and $riskyUsersResult.BlobName) {
        $riskyUsersIndexInput = @{
            Timestamp = $timestamp
            BlobName = $riskyUsersResult.BlobName
        }
        $riskyUsersIndexResult = Invoke-DurableActivity -FunctionName 'IndexRiskyUsersInCosmosDB' -Input $riskyUsersIndexInput
        if ($riskyUsersIndexResult.Success) {
            Write-Verbose "Risky Users indexing complete: $($riskyUsersIndexResult.TotalRiskyUsers) total, $($riskyUsersIndexResult.NewRiskyUsers) new"
        }
        else {
            Write-Warning "Risky Users indexing failed: $($riskyUsersIndexResult.Error)"
        }
    }

    # Index Devices
    $devicesIndexResult = @{ Success = $false; TotalDevices = 0; NewDevices = 0; ModifiedDevices = 0; DeletedDevices = 0; UnchangedDevices = 0; CosmosWriteCount = 0 }
    if ($devicesResult.Success -and $devicesResult.BlobName) {
        $devicesIndexInput = @{
            Timestamp = $timestamp
            BlobName = $devicesResult.BlobName
        }
        $devicesIndexResult = Invoke-DurableActivity -FunctionName 'IndexDevicesInCosmosDB' -Input $devicesIndexInput
        if ($devicesIndexResult.Success) {
            Write-Verbose "Devices indexing complete: $($devicesIndexResult.TotalDevices) total, $($devicesIndexResult.NewDevices) new"
        }
        else {
            Write-Warning "Devices indexing failed: $($devicesIndexResult.Error)"
        }
    }

    # Index CA Policies
    $caPoliciesIndexResult = @{ Success = $false; TotalPolicies = 0; NewPolicies = 0; ModifiedPolicies = 0; DeletedPolicies = 0; UnchangedPolicies = 0; CosmosWriteCount = 0 }
    if ($caPoliciesResult.Success -and $caPoliciesResult.BlobName) {
        $caPoliciesIndexInput = @{
            Timestamp = $timestamp
            BlobName = $caPoliciesResult.BlobName
        }
        $caPoliciesIndexResult = Invoke-DurableActivity -FunctionName 'IndexConditionalAccessInCosmosDB' -Input $caPoliciesIndexInput
        if ($caPoliciesIndexResult.Success) {
            Write-Verbose "CA Policies indexing complete: $($caPoliciesIndexResult.TotalPolicies) total, $($caPoliciesIndexResult.NewPolicies) new"
        }
        else {
            Write-Warning "CA Policies indexing failed: $($caPoliciesIndexResult.Error)"
        }
    }

    # Index App Registrations
    $appRegsIndexResult = @{ Success = $false; TotalAppRegistrations = 0; NewAppRegistrations = 0; ModifiedAppRegistrations = 0; DeletedAppRegistrations = 0; UnchangedAppRegistrations = 0; CosmosWriteCount = 0 }
    if ($appRegsResult.Success -and $appRegsResult.BlobName) {
        $appRegsIndexInput = @{
            Timestamp = $timestamp
            BlobName = $appRegsResult.BlobName
        }
        $appRegsIndexResult = Invoke-DurableActivity -FunctionName 'IndexAppRegistrationsInCosmosDB' -Input $appRegsIndexInput
        if ($appRegsIndexResult.Success) {
            Write-Verbose "App Registrations indexing complete: $($appRegsIndexResult.TotalAppRegistrations) total, $($appRegsIndexResult.NewAppRegistrations) new"
        }
        else {
            Write-Warning "App Registrations indexing failed: $($appRegsIndexResult.Error)"
        }
    }

    # Index User Auth Methods
    $authMethodsIndexResult = @{ Success = $false; TotalUserAuthMethods = 0; NewUserAuthMethods = 0; ModifiedUserAuthMethods = 0; DeletedUserAuthMethods = 0; UnchangedUserAuthMethods = 0; CosmosWriteCount = 0 }
    if ($authMethodsResult.Success -and $authMethodsResult.BlobName) {
        $authMethodsIndexInput = @{
            Timestamp = $timestamp
            BlobName = $authMethodsResult.BlobName
        }
        $authMethodsIndexResult = Invoke-DurableActivity -FunctionName 'IndexUserAuthMethodsInCosmosDB' -Input $authMethodsIndexInput
        if ($authMethodsIndexResult.Success) {
            Write-Verbose "Auth Methods indexing complete: $($authMethodsIndexResult.TotalUserAuthMethods) total, $($authMethodsIndexResult.NewUserAuthMethods) new"
        }
        else {
            Write-Warning "Auth Methods indexing failed: $($authMethodsIndexResult.Error)"
        }
    }

    # Index Directory Roles
    $directoryRolesIndexResult = @{ Success = $false; TotalDirectoryRoles = 0; NewDirectoryRoles = 0; ModifiedDirectoryRoles = 0; DeletedDirectoryRoles = 0; UnchangedDirectoryRoles = 0; CosmosWriteCount = 0 }
    if ($directoryRolesResult.Success -and $directoryRolesResult.BlobName) {
        $directoryRolesIndexInput = @{
            Timestamp = $timestamp
            BlobName = $directoryRolesResult.BlobName
        }
        $directoryRolesIndexResult = Invoke-DurableActivity -FunctionName 'IndexDirectoryRolesInCosmosDB' -Input $directoryRolesIndexInput
        if ($directoryRolesIndexResult.Success) {
            Write-Verbose "Directory Roles indexing complete: $($directoryRolesIndexResult.TotalDirectoryRoles) total, $($directoryRolesIndexResult.NewDirectoryRoles) new"
        }
        else {
            Write-Warning "Directory Roles indexing failed: $($directoryRolesIndexResult.Error)"
        }
    }
    #endregion

    #region Step 5: Index Event Data (Append-only)
    Write-Verbose "Step 5: Indexing event data (append-only, no delta detection)..."

    # Index Sign-In Logs
    $signInLogsIndexResult = @{ Success = $false; TotalSignInLogs = 0; CosmosWriteCount = 0 }
    if ($signInLogsResult.Success -and $signInLogsResult.BlobName) {
        $signInLogsIndexInput = @{
            Timestamp = $timestamp
            BlobName = $signInLogsResult.BlobName
        }
        $signInLogsIndexResult = Invoke-DurableActivity -FunctionName 'IndexSignInLogsInCosmosDB' -Input $signInLogsIndexInput
        if ($signInLogsIndexResult.Success) {
            Write-Verbose "Sign-In Logs indexing complete: $($signInLogsIndexResult.TotalSignInLogs) events indexed"
        }
        else {
            Write-Warning "Sign-In Logs indexing failed: $($signInLogsIndexResult.Error)"
        }
    }

    # Index Directory Audits
    $directoryAuditsIndexResult = @{ Success = $false; TotalDirectoryAudits = 0; CosmosWriteCount = 0 }
    if ($directoryAuditsResult.Success -and $directoryAuditsResult.BlobName) {
        $directoryAuditsIndexInput = @{
            Timestamp = $timestamp
            BlobName = $directoryAuditsResult.BlobName
        }
        $directoryAuditsIndexResult = Invoke-DurableActivity -FunctionName 'IndexDirectoryAuditsInCosmosDB' -Input $directoryAuditsIndexInput
        if ($directoryAuditsIndexResult.Success) {
            Write-Verbose "Directory Audits indexing complete: $($directoryAuditsIndexResult.TotalDirectoryAudits) events indexed"
        }
        else {
            Write-Warning "Directory Audits indexing failed: $($directoryAuditsIndexResult.Error)"
        }
    }
    #endregion

    #region Step 6: Test AI Foundry (Optional)
    Write-Verbose "Step 6: Testing AI Foundry connectivity..."

    $aiTestInput = @{
        Timestamp = $timestamp
        UserCount = $collectionResult.UserCount
        GroupCount = $groupCollectionResult.GroupCount
        ServicePrincipalCount = $spCollectionResult.ServicePrincipalCount
        RiskyUserCount = $riskyUsersResult.RiskyUserCount
        DeviceCount = $devicesResult.DeviceCount
        PolicyCount = $caPoliciesResult.PolicyCount
        AppRegistrationCount = $appRegsResult.AppRegistrationCount
        DirectoryRoleCount = $directoryRolesResult.RoleCount
        SignInLogCount = $signInLogsResult.SignInCount
        DirectoryAuditCount = $directoryAuditsResult.AuditCount
        BlobName = $collectionResult.BlobName
        GroupBlobName = $groupCollectionResult.BlobName
        ServicePrincipalBlobName = $spCollectionResult.BlobName
        CosmosDocumentId = $timestamp
        DeltaSummary = @{
            NewUsers = $indexResult.NewUsers
            ModifiedUsers = $indexResult.ModifiedUsers
            DeletedUsers = $indexResult.DeletedUsers
            NewGroups = $groupIndexResult.NewGroups
            ModifiedGroups = $groupIndexResult.ModifiedGroups
            DeletedGroups = $groupIndexResult.DeletedGroups
            NewServicePrincipals = $spIndexResult.NewServicePrincipals
            ModifiedServicePrincipals = $spIndexResult.ModifiedServicePrincipals
            DeletedServicePrincipals = $spIndexResult.DeletedServicePrincipals
            NewRiskyUsers = $riskyUsersIndexResult.NewRiskyUsers
            NewDevices = $devicesIndexResult.NewDevices
            NewPolicies = $caPoliciesIndexResult.NewPolicies
            NewAppRegistrations = $appRegsIndexResult.NewAppRegistrations
            NewDirectoryRoles = $directoryRolesIndexResult.NewDirectoryRoles
            SignInLogsIndexed = $signInLogsIndexResult.TotalSignInLogs
            DirectoryAuditsIndexed = $directoryAuditsIndexResult.TotalDirectoryAudits
        }
    }

    $aiTestResult = Invoke-DurableActivity `
        -FunctionName 'TestAIFoundry' `
        -Input $aiTestInput

    if ($aiTestResult.Success) {
        Write-Verbose "AI Foundry test successful"
        if ($aiTestResult.AIResponse) {
            Write-Verbose "AI Response: $($aiTestResult.AIResponse)"
        }
    }
    else {
        Write-Verbose "AI Foundry test skipped or failed (non-critical)"
    }
    #endregion
    
    #region Build Final Result
    $finalResult = @{
        OrchestrationId = $Context.InstanceId
        Timestamp = $timestampFormatted
        Status = 'Completed'

        Collection = @{
            # Existing entities
            Users = @{
                Success = $collectionResult.Success
                Count = $collectionResult.UserCount
                BlobPath = $collectionResult.BlobName
            }
            Groups = @{
                Success = $groupCollectionResult.Success
                Count = $groupCollectionResult.GroupCount
                BlobPath = $groupCollectionResult.BlobName
            }
            ServicePrincipals = @{
                Success = $spCollectionResult.Success
                Count = $spCollectionResult.ServicePrincipalCount
                BlobPath = $spCollectionResult.BlobName
            }
            # New entities
            RiskyUsers = @{
                Success = $riskyUsersResult.Success
                Count = $riskyUsersResult.RiskyUserCount
                BlobPath = $riskyUsersResult.BlobName
            }
            Devices = @{
                Success = $devicesResult.Success
                Count = $devicesResult.DeviceCount
                BlobPath = $devicesResult.BlobName
            }
            ConditionalAccessPolicies = @{
                Success = $caPoliciesResult.Success
                Count = $caPoliciesResult.PolicyCount
                BlobPath = $caPoliciesResult.BlobName
            }
            AppRegistrations = @{
                Success = $appRegsResult.Success
                Count = $appRegsResult.AppRegistrationCount
                BlobPath = $appRegsResult.BlobName
            }
            UserAuthMethods = @{
                Success = $authMethodsResult.Success
                Count = $authMethodsResult.UserCount
                BlobPath = $authMethodsResult.BlobName
            }
            DirectoryRoles = @{
                Success = $directoryRolesResult.Success
                Count = $directoryRolesResult.RoleCount
                BlobPath = $directoryRolesResult.BlobName
            }
            # Event data
            SignInLogs = @{
                Success = $signInLogsResult.Success
                Count = $signInLogsResult.SignInCount
                BlobPath = $signInLogsResult.BlobName
            }
            DirectoryAudits = @{
                Success = $directoryAuditsResult.Success
                Count = $directoryAuditsResult.AuditCount
                BlobPath = $directoryAuditsResult.BlobName
            }
        }

        Indexing = @{
            # Existing entities
            Users = @{
                Success = $indexResult.Success
                Total = $indexResult.TotalUsers
                New = $indexResult.NewUsers
                Modified = $indexResult.ModifiedUsers
                Deleted = $indexResult.DeletedUsers
                Unchanged = $indexResult.UnchangedUsers
                CosmosWrites = $indexResult.CosmosWriteCount
            }
            Groups = @{
                Success = $groupIndexResult.Success
                Total = $groupIndexResult.TotalGroups
                New = $groupIndexResult.NewGroups
                Modified = $groupIndexResult.ModifiedGroups
                Deleted = $groupIndexResult.DeletedGroups
                Unchanged = $groupIndexResult.UnchangedGroups
                CosmosWrites = $groupIndexResult.CosmosWriteCount
            }
            ServicePrincipals = @{
                Success = $spIndexResult.Success
                Total = $spIndexResult.TotalServicePrincipals
                New = $spIndexResult.NewServicePrincipals
                Modified = $spIndexResult.ModifiedServicePrincipals
                Deleted = $spIndexResult.DeletedServicePrincipals
                Unchanged = $spIndexResult.UnchangedServicePrincipals
                CosmosWrites = $spIndexResult.CosmosWriteCount
            }
            # New entities
            RiskyUsers = @{
                Success = $riskyUsersIndexResult.Success
                Total = $riskyUsersIndexResult.TotalRiskyUsers
                New = $riskyUsersIndexResult.NewRiskyUsers
                Modified = $riskyUsersIndexResult.ModifiedRiskyUsers
                Deleted = $riskyUsersIndexResult.DeletedRiskyUsers
                Unchanged = $riskyUsersIndexResult.UnchangedRiskyUsers
                CosmosWrites = $riskyUsersIndexResult.CosmosWriteCount
            }
            Devices = @{
                Success = $devicesIndexResult.Success
                Total = $devicesIndexResult.TotalDevices
                New = $devicesIndexResult.NewDevices
                Modified = $devicesIndexResult.ModifiedDevices
                Deleted = $devicesIndexResult.DeletedDevices
                Unchanged = $devicesIndexResult.UnchangedDevices
                CosmosWrites = $devicesIndexResult.CosmosWriteCount
            }
            ConditionalAccessPolicies = @{
                Success = $caPoliciesIndexResult.Success
                Total = $caPoliciesIndexResult.TotalPolicies
                New = $caPoliciesIndexResult.NewPolicies
                Modified = $caPoliciesIndexResult.ModifiedPolicies
                Deleted = $caPoliciesIndexResult.DeletedPolicies
                Unchanged = $caPoliciesIndexResult.UnchangedPolicies
                CosmosWrites = $caPoliciesIndexResult.CosmosWriteCount
            }
            AppRegistrations = @{
                Success = $appRegsIndexResult.Success
                Total = $appRegsIndexResult.TotalAppRegistrations
                New = $appRegsIndexResult.NewAppRegistrations
                Modified = $appRegsIndexResult.ModifiedAppRegistrations
                Deleted = $appRegsIndexResult.DeletedAppRegistrations
                Unchanged = $appRegsIndexResult.UnchangedAppRegistrations
                CosmosWrites = $appRegsIndexResult.CosmosWriteCount
            }
            UserAuthMethods = @{
                Success = $authMethodsIndexResult.Success
                Total = $authMethodsIndexResult.TotalUserAuthMethods
                New = $authMethodsIndexResult.NewUserAuthMethods
                Modified = $authMethodsIndexResult.ModifiedUserAuthMethods
                Deleted = $authMethodsIndexResult.DeletedUserAuthMethods
                Unchanged = $authMethodsIndexResult.UnchangedUserAuthMethods
                CosmosWrites = $authMethodsIndexResult.CosmosWriteCount
            }
            DirectoryRoles = @{
                Success = $directoryRolesIndexResult.Success
                Total = $directoryRolesIndexResult.TotalDirectoryRoles
                New = $directoryRolesIndexResult.NewDirectoryRoles
                Modified = $directoryRolesIndexResult.ModifiedDirectoryRoles
                Deleted = $directoryRolesIndexResult.DeletedDirectoryRoles
                Unchanged = $directoryRolesIndexResult.UnchangedDirectoryRoles
                CosmosWrites = $directoryRolesIndexResult.CosmosWriteCount
            }
            # Event data (append-only, no delta)
            SignInLogs = @{
                Success = $signInLogsIndexResult.Success
                Total = $signInLogsIndexResult.TotalSignInLogs
                CosmosWrites = $signInLogsIndexResult.CosmosWriteCount
            }
            DirectoryAudits = @{
                Success = $directoryAuditsIndexResult.Success
                Total = $directoryAuditsIndexResult.TotalDirectoryAudits
                CosmosWrites = $directoryAuditsIndexResult.CosmosWriteCount
            }
        }

        AIFoundry = @{
            Success = $aiTestResult.Success
            Message = $aiTestResult.Message
            AIResponse = if ($aiTestResult.AIResponse) { $aiTestResult.AIResponse } else { $null }
        }

        Summary = @{
            # Core entity counts
            TotalUsers = $collectionResult.UserCount
            TotalGroups = $groupCollectionResult.GroupCount
            TotalServicePrincipals = $spCollectionResult.ServicePrincipalCount
            TotalRiskyUsers = $riskyUsersResult.RiskyUserCount
            TotalDevices = $devicesResult.DeviceCount
            TotalCAPolicies = $caPoliciesResult.PolicyCount
            TotalAppRegistrations = $appRegsResult.AppRegistrationCount
            TotalDirectoryRoles = $directoryRolesResult.RoleCount
            TotalSignInLogs = $signInLogsResult.SignInCount
            TotalDirectoryAudits = $directoryAuditsResult.AuditCount

            # Overall status
            DataInBlob = $true
            CoreDataInCosmos = ($indexResult.Success -and $groupIndexResult.Success -and $spIndexResult.Success)
            AllDataInCosmos = (
                $indexResult.Success -and
                $groupIndexResult.Success -and
                $spIndexResult.Success -and
                $riskyUsersIndexResult.Success -and
                $devicesIndexResult.Success -and
                $caPoliciesIndexResult.Success -and
                $appRegsIndexResult.Success -and
                $authMethodsIndexResult.Success -and
                $directoryRolesIndexResult.Success -and
                $signInLogsIndexResult.Success -and
                $directoryAuditsIndexResult.Success
            )

            # Change summary
            TotalNewEntities = (
                $indexResult.NewUsers +
                $groupIndexResult.NewGroups +
                $spIndexResult.NewServicePrincipals +
                $riskyUsersIndexResult.NewRiskyUsers +
                $devicesIndexResult.NewDevices +
                $caPoliciesIndexResult.NewPolicies +
                $appRegsIndexResult.NewAppRegistrations +
                $authMethodsIndexResult.NewUserAuthMethods +
                $directoryRolesIndexResult.NewDirectoryRoles
            )
            TotalModifiedEntities = (
                $indexResult.ModifiedUsers +
                $groupIndexResult.ModifiedGroups +
                $spIndexResult.ModifiedServicePrincipals +
                $riskyUsersIndexResult.ModifiedRiskyUsers +
                $devicesIndexResult.ModifiedDevices +
                $caPoliciesIndexResult.ModifiedPolicies +
                $appRegsIndexResult.ModifiedAppRegistrations +
                $authMethodsIndexResult.ModifiedUserAuthMethods +
                $directoryRolesIndexResult.ModifiedDirectoryRoles
            )
            TotalEventsIndexed = (
                $signInLogsIndexResult.TotalSignInLogs +
                $directoryAuditsIndexResult.TotalDirectoryAudits
            )
        }
    }

    Write-Verbose "Orchestration complete successfully"
    Write-Verbose "Entity indexing: $($finalResult.Summary.TotalNewEntities) new, $($finalResult.Summary.TotalModifiedEntities) modified"
    Write-Verbose "Event indexing: $($finalResult.Summary.TotalEventsIndexed) events"

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


