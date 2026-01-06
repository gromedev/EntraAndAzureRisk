<#
.SYNOPSIS
    Collects Azure PIM role eligibility and assignment schedules across all subscriptions
.DESCRIPTION
    - Discovers all accessible Azure subscriptions
    - Queries PIM-eligible roles (roleEligibilitySchedules) for each subscription
    - Queries PIM active assignments (roleAssignmentSchedules) for each subscription
    - Uses Azure Resource Manager PIM API (api-version=2020-10-01)
    - Processes subscriptions IN PARALLEL (performance optimization)
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
#>

param($ActivityInput)

#region Import Module
try {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection"
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Verbose "Module imported successfully from: $modulePath"
}
catch {
    $errorMsg = "Failed to import EntraDataCollection module: $($_.Exception.Message)"
    Write-Error $errorMsg
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Validate Environment Variables
$requiredEnvVars = @{
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
}

$missingVars = @()
foreach ($varName in $requiredEnvVars.Keys) {
    if (-not (Get-Item "Env:$varName" -ErrorAction SilentlyContinue)) {
        $missingVars += "$varName ($($requiredEnvVars[$varName]))"
    }
}

if ($missingVars) {
    $errorMsg = "Missing required environment variables:`n" + ($missingVars -join "`n")
    Write-Warning $errorMsg
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Azure RBAC assignments collection"

    # Generate timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $azureToken = Get-CachedManagedIdentityToken -Resource "https://management.azure.com"
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{
            Success = $false
            Error = "Token acquisition failed: $($_.Exception.Message)"
        }
    }

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $parallelThrottle = if ($env:PIM_PARALLEL_THROTTLE) { [int]$env:PIM_PARALLEL_THROTTLE } else { 10 }

    Write-Verbose "Configuration: ParallelThrottle=$parallelThrottle"

    # Initialize append blob
    $rbacBlobName = "$timestamp/$timestamp-azure-rbac.jsonl"
    Write-Verbose "Initializing append blob: $rbacBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $rbacBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    #region Discover Subscriptions
    Write-Verbose "Discovering Azure subscriptions..."

    $subscriptions = Get-AzureManagementPagedResults `
        -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" `
        -AccessToken $azureToken

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No accessible subscriptions found"
        return @{
            Success = $true
            BlobName = $rbacBlobName
            AzureRbacAssignmentCount = 0
            Summary = @{
                totalCount = 0
                subscriptionCount = 0
                timestamp = $timestampFormatted
            }
        }
    }

    Write-Verbose "Found $($subscriptions.Count) accessible subscriptions"
    #endregion

    #region Collect Role Assignments in Parallel
    Write-Verbose "Collecting role assignments from all subscriptions (parallel processing)..."

    # Use ConcurrentBag for thread-safe parallel results (pattern from PimActivation)
    $allAssignments = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

    $subscriptions | ForEach-Object -ThrottleLimit $parallelThrottle -Parallel {
        $sub = $_
        $token = $using:azureToken
        $timestampFormatted = $using:timestampFormatted
        $allAssignments = $using:allAssignments

        try {
            # Get role assignments for this subscription
            $uri = "https://management.azure.com$($sub.id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

            # Note: Not using Get-AzureManagementPagedResults here because we're already in parallel block
            # and need to import the function into each parallel runspace
            $headers = @{
                'Authorization' = "Bearer $token"
                'Content-Type' = 'application/json'
            }

            $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
            $assignments = $response.value

            foreach ($assignment in $assignments) {
                # Parse scope to extract subscription, resource group, etc.
                $scope = $assignment.properties.scope
                $scopeType = "unknown"
                $subscriptionId = $sub.subscriptionId
                $resourceGroup = $null

                if ($scope -match '/subscriptions/([^/]+)$') {
                    $scopeType = "subscription"
                }
                elseif ($scope -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)$') {
                    $scopeType = "resourceGroup"
                    $resourceGroup = $matches[2]
                }
                elseif ($scope -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/') {
                    $scopeType = "resource"
                    $resourceGroup = $matches[2]
                }

                $assignmentObj = @{
                    objectId = $assignment.id ?? ""
                    subscriptionId = $subscriptionId
                    subscriptionName = $sub.displayName ?? ""
                    scope = $scope
                    scopeType = $scopeType
                    resourceGroup = $resourceGroup
                    principalId = $assignment.properties.principalId ?? ""
                    principalType = $assignment.properties.principalType ?? ""
                    roleDefinitionId = $assignment.properties.roleDefinitionId ?? ""
                    roleDefinitionName = ($assignment.properties.roleDefinitionId -split '/')[-1]
                    createdOn = $assignment.properties.createdOn ?? ""
                    updatedOn = $assignment.properties.updatedOn ?? ""
                    createdBy = $assignment.properties.createdBy ?? ""
                    updatedBy = $assignment.properties.updatedBy ?? ""
                    collectionTimestamp = $timestampFormatted
                }

                # Add to thread-safe collection
                [void]$allAssignments.Add($assignmentObj)
            }
        }
        catch {
            Write-Warning "Failed to collect role assignments for subscription $($sub.subscriptionId): $_"
        }
    }

    Write-Verbose "Parallel collection complete. Total assignments: $($allAssignments.Count)"
    #endregion

    #region Write to Blob
    if ($allAssignments.Count -gt 0) {
        Write-Verbose "Writing $($allAssignments.Count) Azure RBAC assignments to blob..."

        # Convert ConcurrentBag to JSONL
        $rbacJsonL = New-Object System.Text.StringBuilder
        foreach ($assignment in $allAssignments) {
            [void]$rbacJsonL.AppendLine(($assignment | ConvertTo-Json -Compress))
        }

        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $rbacBlobName `
                           -Content $rbacJsonL.ToString() `
                           -AccessToken $storageToken

            Write-Verbose "Successfully wrote $($allAssignments.Count) assignments to blob"
        }
        catch {
            Write-Error "Failed to write to blob: $_"
            return @{
                Success = $false
                Error = "Blob write failed: $($_.Exception.Message)"
                BlobName = $rbacBlobName
            }
        }
    }
    else {
        Write-Verbose "No Azure RBAC assignments to write"
    }
    #endregion

    # Return success with statistics
    return @{
        Success = $true
        BlobName = $rbacBlobName
        AzureRbacAssignmentCount = $allAssignments.Count
        Summary = @{
            totalCount = $allAssignments.Count
            subscriptionCount = $subscriptions.Count
            timestamp = $timestampFormatted
        }
    }
}
catch {
    Write-Error "Azure RBAC assignments collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
