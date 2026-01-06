<#
.SYNOPSIS
    Collects Entra PIM role assignments (eligible and active) and streams to Blob Storage
.DESCRIPTION
    - Queries role eligibility schedules and assignment schedules from Graph API
    - Uses $expand to get role definitions and principals in single call (reduces API calls)
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
    'TENANT_ID' = 'Entra ID tenant ID'
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
    Write-Verbose "Starting Entra PIM role assignments collection"

    # Generate timestamps
    $now = (Get-Date).ToUniversalTime()
    $timestamp = $now.ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"

    # Get access tokens
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $graphToken = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
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
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    Write-Verbose "Configuration: Batch=$batchSize"

    # Initialize counters
    $rolesJsonL = New-Object System.Text.StringBuilder(1048576)
    $totalCount = 0
    $eligibleCount = 0
    $activeCount = 0

    # Initialize append blob
    $rolesBlobName = "$timestamp/$timestamp-entra-pim-roles.jsonl"
    Write-Verbose "Initializing append blob: $rolesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $rolesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    #region Collect Eligible Role Assignments
    Write-Verbose "Collecting eligible role assignments..."

    # Use $expand to get role definitions and principals in single call
    $selectFields = "id,principalId,roleDefinitionId,memberType,status,scheduleInfo,createdDateTime,modifiedDateTime"
    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve eligible role batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($assignment in $batch) {
            $assignmentObj = @{
                objectId = $assignment.id ?? ""
                assignmentType = "eligible"
                principalId = $assignment.principalId ?? ""
                roleDefinitionId = $assignment.roleDefinitionId ?? ""
                roleDefinitionName = $assignment.roleDefinition.displayName ?? ""
                rolTemplateId = $assignment.roleDefinition.templateId ?? ""
                principalDisplayName = $assignment.principal.displayName ?? ""
                principalType = $assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                memberType = $assignment.memberType ?? ""
                status = $assignment.status ?? ""
                scheduleInfo = $assignment.scheduleInfo ?? @{}
                createdDateTime = $assignment.createdDateTime ?? ""
                modifiedDateTime = $assignment.modifiedDateTime ?? ""
                collectionTimestamp = $timestampFormatted
            }

            [void]$rolesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
            $totalCount++
            $eligibleCount++
        }

        Write-Verbose "Processed $eligibleCount eligible assignments so far..."
    }
    #endregion

    #region Collect Active Role Assignments
    Write-Verbose "Collecting active role assignments..."

    $nextLink = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentSchedules?`$select=$selectFields&`$expand=roleDefinition,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve active role batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($assignment in $batch) {
            $assignmentObj = @{
                objectId = $assignment.id ?? ""
                assignmentType = "active"
                principalId = $assignment.principalId ?? ""
                roleDefinitionId = $assignment.roleDefinitionId ?? ""
                roleDefinitionName = $assignment.roleDefinition.displayName ?? ""
                roleTemplateId = $assignment.roleDefinition.templateId ?? ""
                principalDisplayName = $assignment.principal.displayName ?? ""
                principalType = $assignment.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                memberType = $assignment.memberType ?? ""
                status = $assignment.status ?? ""
                scheduleInfo = $assignment.scheduleInfo ?? @{}
                createdDateTime = $assignment.createdDateTime ?? ""
                modifiedDateTime = $assignment.modifiedDateTime ?? ""
                collectionTimestamp = $timestampFormatted
            }

            [void]$rolesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
            $totalCount++
            $activeCount++
        }

        Write-Verbose "Processed $activeCount active assignments so far..."
    }
    #endregion

    #region Write to Blob
    if ($rolesJsonL.Length -gt 0) {
        Write-Verbose "Writing $totalCount PIM role assignments to blob..."
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $rolesBlobName `
                           -Content $rolesJsonL.ToString() `
                           -AccessToken $storageToken

            Write-Verbose "Successfully wrote $totalCount assignments to blob"
        }
        catch {
            Write-Error "Failed to write to blob: $_"
            return @{
                Success = $false
                Error = "Blob write failed: $($_.Exception.Message)"
                BlobName = $rolesBlobName
            }
        }
    }
    else {
        Write-Verbose "No PIM role assignments to write"
    }
    #endregion

    # Return success with statistics
    return @{
        Success = $true
        BlobName = $rolesBlobName
        PimRoleCount = $totalCount
        Summary = @{
            totalCount = $totalCount
            eligibleCount = $eligibleCount
            activeCount = $activeCount
            timestamp = $timestampFormatted
        }
    }
}
catch {
    Write-Error "Entra PIM role collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
