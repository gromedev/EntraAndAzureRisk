
#region Durable Functions Orchestrator - DELTA ARCHITECTURE
<#
.SYNOPSIS
    Orchestrates Entra user and group data collection with delta change detection
.DESCRIPTION
    Workflow:
    1. CollectEntraUsers + CollectEntraGroups (Parallel) - Stream to Blob Storage (2-3 minutes)
    2. IndexInCosmosDB + IndexGroupsInCosmosDB (Parallel) - Delta detection and write changes only
    3. TestAIFoundry - Optional connectivity test

    Benefits of this flow:
    - Fast parallel collection (streaming to Blob)
    - Decoupled indexing (can retry independently)
    - Delta detection reduces Cosmos writes
    - Blob acts as checkpoint/buffer

    Partial Success Pattern:
    - CollectEntraUsers fails → STOP (critical, no data)
    - CollectEntraGroups fails → CONTINUE (users still indexed)
    - IndexInCosmosDB fails → CONTINUE (data safe in Blob, can retry)
    - IndexGroupsInCosmosDB fails → CONTINUE (data safe in Blob, can retry)
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
    
    #region Step 1: Collect Entra Users and Groups (Parallel)
    Write-Verbose "Step 1: Collecting users and groups from Entra ID in parallel..."

    $collectionInput = @{
        Timestamp = $timestamp
    }

    # Start both collections in parallel
    $userCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraUsers' `
        -Input $collectionInput `
        -NoWait

    $groupCollectionTask = Invoke-DurableActivity `
        -FunctionName 'CollectEntraGroups' `
        -Input $collectionInput `
        -NoWait

    # Wait for both to complete
    $collectionResults = Wait-ActivityFunction -Task @($userCollectionTask, $groupCollectionTask)
    $collectionResult = $collectionResults[0]      # Users
    $groupCollectionResult = $collectionResults[1] # Groups

    # Validate both succeeded (fail fast on users, warn on groups)
    if (-not $collectionResult.Success) {
        throw "User collection failed: $($collectionResult.Error)"
    }

    if (-not $groupCollectionResult.Success) {
        Write-Warning "Group collection failed: $($groupCollectionResult.Error)"
        # Continue with user indexing even if groups failed
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

    Write-Verbose "Collection complete:"
    Write-Verbose "  Users: $($collectionResult.UserCount) users"
    Write-Verbose "  Groups: $($groupCollectionResult.GroupCount) groups"
    Write-Verbose "  User blob: $($collectionResult.BlobName)"
    Write-Verbose "  Group blob: $($groupCollectionResult.BlobName)"
    #endregion
    
    #region Step 2: Index Users and Groups in Cosmos DB (Parallel with Retry)
    Write-Verbose "Step 2: Indexing users and groups in Cosmos DB with delta detection..."

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
    #endregion
    
    #region Step 3: Test AI Foundry (Optional)
    Write-Verbose "Step 3: Testing AI Foundry connectivity..."

    $aiTestInput = @{
        Timestamp = $timestamp
        UserCount = $collectionResult.UserCount
        GroupCount = $groupCollectionResult.GroupCount
        BlobName = $collectionResult.BlobName
        GroupBlobName = $groupCollectionResult.BlobName
        CosmosDocumentId = $timestamp
        DeltaSummary = @{
            NewUsers = $indexResult.NewUsers
            ModifiedUsers = $indexResult.ModifiedUsers
            DeletedUsers = $indexResult.DeletedUsers
            NewGroups = $groupIndexResult.NewGroups
            ModifiedGroups = $groupIndexResult.ModifiedGroups
            DeletedGroups = $groupIndexResult.DeletedGroups
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
            Users = @{
                Success = $collectionResult.Success
                UserCount = $collectionResult.UserCount
                BlobPath = $collectionResult.BlobName
                Duration = "2-3 minutes"
            }
            Groups = @{
                Success = $groupCollectionResult.Success
                GroupCount = $groupCollectionResult.GroupCount
                BlobPath = $groupCollectionResult.BlobName
                Duration = "1-2 minutes"
            }
        }

        Indexing = @{
            Users = @{
                Success = $indexResult.Success
                TotalUsers = $indexResult.TotalUsers
                Changes = @{
                    New = $indexResult.NewUsers
                    Modified = $indexResult.ModifiedUsers
                    Deleted = $indexResult.DeletedUsers
                    Unchanged = $indexResult.UnchangedUsers
                }
                CosmosWrites = $indexResult.CosmosWriteCount
                CosmosWriteReduction = if ($indexResult.TotalUsers -gt 0) {
                    [math]::Round((1 - ($indexResult.CosmosWriteCount / $indexResult.TotalUsers)) * 100, 2)
                } else { 0 }
            }
            Groups = @{
                Success = $groupIndexResult.Success
                TotalGroups = $groupIndexResult.TotalGroups
                Changes = @{
                    New = $groupIndexResult.NewGroups
                    Modified = $groupIndexResult.ModifiedGroups
                    Deleted = $groupIndexResult.DeletedGroups
                    Unchanged = $groupIndexResult.UnchangedGroups
                }
                CosmosWrites = $groupIndexResult.CosmosWriteCount
                CosmosWriteReduction = if ($groupIndexResult.TotalGroups -gt 0) {
                    [math]::Round((1 - ($groupIndexResult.CosmosWriteCount / $groupIndexResult.TotalGroups)) * 100, 2)
                } else { 0 }
            }
        }

        AIFoundry = @{
            Success = $aiTestResult.Success
            Message = $aiTestResult.Message
            AIResponse = if ($aiTestResult.AIResponse) { $aiTestResult.AIResponse } else { $null }
        }

        Summary = @{
            TotalUsers = $collectionResult.UserCount
            TotalGroups = $groupCollectionResult.GroupCount
            UserChanges = @{
                New = $indexResult.NewUsers
                Modified = $indexResult.ModifiedUsers
                Deleted = $indexResult.DeletedUsers
                Unchanged = $indexResult.UnchangedUsers
            }
            GroupChanges = @{
                New = $groupIndexResult.NewGroups
                Modified = $groupIndexResult.ModifiedGroups
                Deleted = $groupIndexResult.DeletedGroups
                Unchanged = $groupIndexResult.UnchangedGroups
            }
            DataInBlob = $true
            DataInCosmos = ($indexResult.Success -and $groupIndexResult.Success)
            WriteEfficiency = @{
                Users = if ($indexResult.TotalUsers -gt 0 -and $indexResult.Success) {
                    "$($indexResult.CosmosWriteCount) writes instead of $($indexResult.TotalUsers) ($(100 - [math]::Round(($indexResult.CosmosWriteCount / $indexResult.TotalUsers) * 100, 2))% reduction)"
                } else {
                    "No writes completed"
                }
                Groups = if ($groupIndexResult.TotalGroups -gt 0 -and $groupIndexResult.Success) {
                    "$($groupIndexResult.CosmosWriteCount) writes instead of $($groupIndexResult.TotalGroups) ($(100 - [math]::Round(($groupIndexResult.CosmosWriteCount / $groupIndexResult.TotalGroups) * 100, 2))% reduction)"
                } else {
                    "No writes completed"
                }
            }
        }
    }

    Write-Verbose "Orchestration complete successfully"
    Write-Verbose "User write efficiency: $($finalResult.Indexing.Users.CosmosWriteReduction)% reduction"
    Write-Verbose "Group write efficiency: $($finalResult.Indexing.Groups.CosmosWriteReduction)% reduction"

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


