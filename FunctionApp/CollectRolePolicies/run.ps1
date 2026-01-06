<#
.SYNOPSIS
    Collects role management policies and assignments from Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries role management policies (activation settings, MFA, approval rules)
    - Queries policy assignments (which policies apply to which roles)
    - Uses $expand to get rules and assignments in single call
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
    Write-Verbose "Starting role management policies collection"

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
    $policiesJsonL = New-Object System.Text.StringBuilder(1048576)
    $policyCount = 0
    $assignmentCount = 0

    # Initialize append blob
    $policiesBlobName = "$timestamp/$timestamp-role-policies.jsonl"
    Write-Verbose "Initializing append blob: $policiesBlobName"

    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName $containerName `
                              -BlobName $policiesBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }

    #region Collect Role Management Policies
    Write-Verbose "Collecting role management policies..."

    # Use $expand to get rules in single call
    $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicies?`$expand=rules,effectiveRules&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve policy batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($policy in $batch) {
            $policyObj = @{
                objectId = $policy.id ?? ""
                displayName = $policy.displayName ?? ""
                description = $policy.description ?? ""
                isOrganizationDefault = $policy.isOrganizationDefault ?? $false
                scope = $policy.scope ?? ""
                scopeId = $policy.scopeId ?? ""
                scopeType = $policy.scopeType ?? ""
                rules = $policy.rules ?? @()
                effectiveRules = $policy.effectiveRules ?? @()
                lastModifiedDateTime = $policy.lastModifiedDateTime ?? ""
                lastModifiedBy = $policy.lastModifiedBy ?? @{}
                collectionTimestamp = $timestampFormatted
                dataType = "policy"
            }

            [void]$policiesJsonL.AppendLine(($policyObj | ConvertTo-Json -Compress -Depth 10))
            $policyCount++
        }

        Write-Verbose "Processed $policyCount policies so far..."
    }
    #endregion

    #region Collect Policy Assignments
    Write-Verbose "Collecting role management policy assignments..."

    # Query policy assignments (maps policies to roles)
    $nextLink = "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$expand=policy&`$top=$batchSize"

    while ($nextLink) {
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $batch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve policy assignment batch: $_"
            break
        }

        if ($batch.Count -eq 0) { break }

        foreach ($assignment in $batch) {
            $assignmentObj = @{
                objectId = $assignment.id ?? ""
                policyId = $assignment.policyId ?? ""
                roleDefinitionId = $assignment.roleDefinitionId ?? ""
                scope = $assignment.scope ?? ""
                scopeId = $assignment.scopeId ?? ""
                scopeType = $assignment.scopeType ?? ""
                policyDisplayName = $assignment.policy.displayName ?? ""
                policyIsOrganizationDefault = $assignment.policy.isOrganizationDefault ?? $false
                collectionTimestamp = $timestampFormatted
                dataType = "policyAssignment"
            }

            [void]$policiesJsonL.AppendLine(($assignmentObj | ConvertTo-Json -Compress))
            $assignmentCount++
        }

        Write-Verbose "Processed $assignmentCount policy assignments so far..."
    }
    #endregion

    #region Write to Blob
    $totalCount = $policyCount + $assignmentCount

    if ($policiesJsonL.Length -gt 0) {
        Write-Verbose "Writing $totalCount role policies/assignments to blob..."
        try {
            Add-BlobContent -StorageAccountName $storageAccountName `
                           -ContainerName $containerName `
                           -BlobName $policiesBlobName `
                           -Content $policiesJsonL.ToString() `
                           -AccessToken $storageToken

            Write-Verbose "Successfully wrote $totalCount items to blob"
        }
        catch {
            Write-Error "Failed to write to blob: $_"
            return @{
                Success = $false
                Error = "Blob write failed: $($_.Exception.Message)"
                BlobName = $policiesBlobName
            }
        }
    }
    else {
        Write-Verbose "No role policies to write"
    }
    #endregion

    # Return success with statistics
    return @{
        Success = $true
        BlobName = $policiesBlobName
        RolePolicyCount = $totalCount
        Summary = @{
            totalCount = $totalCount
            policyCount = $policyCount
            assignmentCount = $assignmentCount
            timestamp = $timestampFormatted
        }
    }
}
catch {
    Write-Error "Role policies collection failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
