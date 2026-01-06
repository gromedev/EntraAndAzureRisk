<#
.SYNOPSIS
    Collects PIM-enabled group memberships (eligible and active) and streams to Blob Storage
.DESCRIPTION
    - Queries group eligibility schedules and assignment schedules from Graph API
    - Uses $expand to get group and principal details in single call
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
    Write-Verbose "Starting PIM group memberships collection"

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
    $membershipsJsonL = New-Object System.Text.StringBuilder(1048576)
    $totalCount = 0
    $eligibleCount = 0
    $activeCount = 0

    # Initialize append blob
    $membershipsBlobName = "$timestamp/$timestamp-pim-groups.jsonl"
    Write-Verbose "Initializing append blob: $membershipsBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $membershipsBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    #region Collect Eligible Group Memberships
    Write-Verbose "Collecting eligible group memberships..."

    $selectFields = "id,principalId,groupId,accessId,memberType,status,scheduleInfo,createdDateTime"
    $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve eligible membership batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($membership in $batch) {
            $membershipObj = @{
                objectId = $membership.id ?? ""
                assignmentType = "eligible"
                principalId = $membership.principalId ?? ""
                groupId = $membership.groupId ?? ""
                groupDisplayName = $membership.group.displayName ?? ""
                accessId = $membership.accessId ?? ""  # member or owner
                principalDisplayName = $membership.principal.displayName ?? ""
                principalType = $membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                memberType = $membership.memberType ?? ""
                status = $membership.status ?? ""
                scheduleInfo = $membership.scheduleInfo ?? @{}
                createdDateTime = $membership.createdDateTime ?? ""
                collectionTimestamp = $timestampFormatted
            }

            [void]$membershipsJsonL.AppendLine(($membershipObj | ConvertTo-Json -Compress))
            $totalCount++
            $eligibleCount++
        }

        Write-Verbose "Processed $eligibleCount eligible memberships so far..."
    }
    #endregion

    #region Collect Active Group Memberships
    Write-Verbose "Collecting active group memberships..."

    $nextLink = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentSchedules?`$select=$selectFields&`$expand=group,principal&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve active membership batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($membership in $batch) {
            $membershipObj = @{
                objectId = $membership.id ?? ""
                assignmentType = "active"
                principalId = $membership.principalId ?? ""
                groupId = $membership.groupId ?? ""
                groupDisplayName = $membership.group.displayName ?? ""
                accessId = $membership.accessId ?? ""  # member or owner
                principalDisplayName = $membership.principal.displayName ?? ""
                principalType = $membership.principal.'@odata.type' -replace '#microsoft\.graph\.', '' ?? ""
                memberType = $membership.memberType ?? ""
                status = $membership.status ?? ""
                scheduleInfo = $membership.scheduleInfo ?? @{}
                createdDateTime = $membership.createdDateTime ?? ""
                collectionTimestamp = $timestampFormatted
            }

            [void]$membershipsJsonL.AppendLine(($membershipObj | ConvertTo-Json -Compress))
            $totalCount++
            $activeCount++
        }

        Write-Verbose "Processed $activeCount active memberships so far..."
    }
    #endregion

    #region Write to Blob
    if ($membershipsJsonL.Length -gt 0) {
        Write-Verbose "Writing $totalCount PIM group memberships to blob..."
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $membershipsBlobName `
                           -Content $membershipsJsonL.ToString() `
                           -AccessToken $storageToken

            Write-Verbose "Successfully wrote $totalCount memberships to blob"
        }
        catch {
            Write-Error "Failed to write to blob: $_"
            return @{
                Success = $false
                Error = "Blob write failed: $($_.Exception.Message)"
                BlobName = $membershipsBlobName
            }
        }
    }
    else {
        Write-Verbose "No PIM group memberships to write"
    }
    #endregion

    # Return success with statistics
    return @{
        Success = $true
        BlobName = $membershipsBlobName
        PimGroupMembershipCount = $totalCount
        Summary = @{
            totalCount = $totalCount
            eligibleCount = $eligibleCount
            activeCount = $activeCount
            timestamp = $timestampFormatted
        }
    }
}
catch {
    Write-Error "PIM group memberships collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
