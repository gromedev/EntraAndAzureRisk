<#
.SYNOPSIS
    Derives virtual "gate" edges from Intune policies to their targeted groups
.DESCRIPTION
    V3.5 Feature: Virtual Edge Derivation

    Reads Intune policies from Cosmos DB and derives gate edges showing
    which groups are targeted by compliance and app protection policies:
    - compliancePolicyTargets: compliancePolicy → group
    - appProtectionPolicyTargets: appProtectionPolicy → group

    These edges enable:
    - Understanding which devices/users are gated by compliance requirements
    - Mapping MAM policy coverage to group membership
    - Risk analysis: "If this group is compromised, which policies are bypassed?"

    Output: Derived gate edges written to edges container
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
    return @{ Success = $false; Error = $errorMsg }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting virtual edge derivation from Intune policies"

    # Get timestamp from orchestrator
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

    # Get Cosmos DB connection info
    $cosmosConnectionString = $env:CosmosDbConnectionString
    if (-not $cosmosConnectionString) {
        throw "CosmosDbConnectionString environment variable not set"
    }

    # Parse connection string
    $connParts = @{}
    $cosmosConnectionString.Split(';') | ForEach-Object {
        if ($_ -match '(.+?)=(.+)') {
            $connParts[$matches[1]] = $matches[2]
        }
    }
    $cosmosEndpoint = $connParts['AccountEndpoint']
    $cosmosKey = $connParts['AccountKey']
    $databaseName = "EntraData"

    # Stats tracking
    $stats = @{
        CompliancePoliciesProcessed = 0
        AppProtectionPoliciesProcessed = 0
        CompliancePolicyTargetEdges = 0
        AppProtectionPolicyTargetEdges = 0
        AllUsersTargets = 0
        AllDevicesTargets = 0
        TotalDerived = 0
        Errors = 0
    }

    # Collected virtual edges
    $virtualEdges = [System.Collections.Generic.List[object]]::new()

    #region Query Policies from Cosmos DB
    Write-Verbose "=== Querying Intune Policies from Cosmos DB ==="

    # Query compliance policies
    $complianceQuery = "SELECT * FROM c WHERE c.policyType = 'compliancePolicy' AND c.deleted != true"
    $appProtectionQuery = "SELECT * FROM c WHERE c.policyType = 'appProtectionPolicy' AND c.deleted != true"

    $compliancePolicies = @()
    $appProtectionPolicies = @()

    try {
        $compliancePolicies = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                                     -Key $cosmosKey `
                                                     -DatabaseName $databaseName `
                                                     -ContainerName "policies" `
                                                     -Query $complianceQuery `
                                                     -PartitionKey "compliancePolicy"

        Write-Verbose "Found $($compliancePolicies.Count) compliance policies"
    }
    catch {
        Write-Warning "Error querying compliance policies: $_"
        $stats.Errors++
    }

    try {
        $appProtectionPolicies = Invoke-CosmosDbQuery -Endpoint $cosmosEndpoint `
                                                        -Key $cosmosKey `
                                                        -DatabaseName $databaseName `
                                                        -ContainerName "policies" `
                                                        -Query $appProtectionQuery `
                                                        -PartitionKey "appProtectionPolicy"

        Write-Verbose "Found $($appProtectionPolicies.Count) app protection policies"
    }
    catch {
        Write-Warning "Error querying app protection policies: $_"
        $stats.Errors++
    }
    #endregion

    #region Phase 1: Derive Compliance Policy Target Edges
    Write-Verbose "=== Phase 1: Deriving Compliance Policy Target Edges ==="

    foreach ($policy in $compliancePolicies) {
        $stats.CompliancePoliciesProcessed++

        if (-not $policy.assignments -or $policy.assignments.Count -eq 0) {
            continue
        }

        foreach ($assignment in $policy.assignments) {
            $targetType = $assignment.targetType

            # Handle different target types
            switch -Regex ($targetType) {
                'groupAssignmentTarget' {
                    # Direct group assignment
                    if ($assignment.groupId) {
                        $virtualEdge = @{
                            id = [guid]::NewGuid().ToString()
                            objectId = "$($policy.objectId)_$($assignment.groupId)_compliancePolicyTargets"
                            edgeType = "compliancePolicyTargets"
                            sourceId = $policy.objectId
                            sourceType = "compliancePolicy"
                            sourceDisplayName = $policy.displayName
                            sourcePlatform = $policy.platform
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = $null  # Would need group lookup
                            deleted = $false
                            assignmentFilterType = $assignment.deviceAndAppManagementAssignmentFilterType
                            collectionTimestamp = $timestampFormatted
                            lastModified = $timestampFormatted
                        }

                        $virtualEdges.Add($virtualEdge)
                        $stats.CompliancePolicyTargetEdges++
                    }
                }
                'allLicensedUsersAssignmentTarget' {
                    # All users target
                    $virtualEdge = @{
                        id = [guid]::NewGuid().ToString()
                        objectId = "$($policy.objectId)_allUsers_compliancePolicyTargets"
                        edgeType = "compliancePolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "compliancePolicy"
                        sourceDisplayName = $policy.displayName
                        sourcePlatform = $policy.platform
                        targetId = "allUsers"
                        targetType = "virtual"
                        targetDisplayName = "All Licensed Users"
                        deleted = $false
                        collectionTimestamp = $timestampFormatted
                        lastModified = $timestampFormatted
                    }

                    $virtualEdges.Add($virtualEdge)
                    $stats.CompliancePolicyTargetEdges++
                    $stats.AllUsersTargets++
                }
                'allDevicesAssignmentTarget' {
                    # All devices target
                    $virtualEdge = @{
                        id = [guid]::NewGuid().ToString()
                        objectId = "$($policy.objectId)_allDevices_compliancePolicyTargets"
                        edgeType = "compliancePolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "compliancePolicy"
                        sourceDisplayName = $policy.displayName
                        sourcePlatform = $policy.platform
                        targetId = "allDevices"
                        targetType = "virtual"
                        targetDisplayName = "All Devices"
                        deleted = $false
                        collectionTimestamp = $timestampFormatted
                        lastModified = $timestampFormatted
                    }

                    $virtualEdges.Add($virtualEdge)
                    $stats.CompliancePolicyTargetEdges++
                    $stats.AllDevicesTargets++
                }
                'exclusionGroupAssignmentTarget' {
                    # Exclusion group - create edge with exclusion flag
                    if ($assignment.groupId) {
                        $virtualEdge = @{
                            id = [guid]::NewGuid().ToString()
                            objectId = "$($policy.objectId)_$($assignment.groupId)_compliancePolicyExcludes"
                            edgeType = "compliancePolicyExcludes"
                            sourceId = $policy.objectId
                            sourceType = "compliancePolicy"
                            sourceDisplayName = $policy.displayName
                            sourcePlatform = $policy.platform
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = $null
                            deleted = $false
                            isExclusion = $true
                            collectionTimestamp = $timestampFormatted
                            lastModified = $timestampFormatted
                        }

                        $virtualEdges.Add($virtualEdge)
                        $stats.CompliancePolicyTargetEdges++
                    }
                }
            }
        }
    }
    #endregion

    #region Phase 2: Derive App Protection Policy Target Edges
    Write-Verbose "=== Phase 2: Deriving App Protection Policy Target Edges ==="

    foreach ($policy in $appProtectionPolicies) {
        $stats.AppProtectionPoliciesProcessed++

        if (-not $policy.assignments -or $policy.assignments.Count -eq 0) {
            continue
        }

        foreach ($assignment in $policy.assignments) {
            $targetType = $assignment.targetType

            switch -Regex ($targetType) {
                'groupAssignmentTarget' {
                    if ($assignment.groupId) {
                        $virtualEdge = @{
                            id = [guid]::NewGuid().ToString()
                            objectId = "$($policy.objectId)_$($assignment.groupId)_appProtectionPolicyTargets"
                            edgeType = "appProtectionPolicyTargets"
                            sourceId = $policy.objectId
                            sourceType = "appProtectionPolicy"
                            sourceDisplayName = $policy.displayName
                            sourcePlatform = $policy.platform
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = $null
                            deleted = $false
                            protectedAppCount = $policy.protectedAppCount
                            collectionTimestamp = $timestampFormatted
                            lastModified = $timestampFormatted
                        }

                        $virtualEdges.Add($virtualEdge)
                        $stats.AppProtectionPolicyTargetEdges++
                    }
                }
                'allLicensedUsersAssignmentTarget' {
                    $virtualEdge = @{
                        id = [guid]::NewGuid().ToString()
                        objectId = "$($policy.objectId)_allUsers_appProtectionPolicyTargets"
                        edgeType = "appProtectionPolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "appProtectionPolicy"
                        sourceDisplayName = $policy.displayName
                        sourcePlatform = $policy.platform
                        targetId = "allUsers"
                        targetType = "virtual"
                        targetDisplayName = "All Licensed Users"
                        deleted = $false
                        protectedAppCount = $policy.protectedAppCount
                        collectionTimestamp = $timestampFormatted
                        lastModified = $timestampFormatted
                    }

                    $virtualEdges.Add($virtualEdge)
                    $stats.AppProtectionPolicyTargetEdges++
                    $stats.AllUsersTargets++
                }
                'exclusionGroupAssignmentTarget' {
                    if ($assignment.groupId) {
                        $virtualEdge = @{
                            id = [guid]::NewGuid().ToString()
                            objectId = "$($policy.objectId)_$($assignment.groupId)_appProtectionPolicyExcludes"
                            edgeType = "appProtectionPolicyExcludes"
                            sourceId = $policy.objectId
                            sourceType = "appProtectionPolicy"
                            sourceDisplayName = $policy.displayName
                            sourcePlatform = $policy.platform
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = $null
                            deleted = $false
                            isExclusion = $true
                            collectionTimestamp = $timestampFormatted
                            lastModified = $timestampFormatted
                        }

                        $virtualEdges.Add($virtualEdge)
                        $stats.AppProtectionPolicyTargetEdges++
                    }
                }
            }
        }
    }
    #endregion

    $stats.TotalDerived = $virtualEdges.Count
    Write-Verbose "Derived $($stats.TotalDerived) virtual edges total"
    Write-Verbose "  Compliance policy targets: $($stats.CompliancePolicyTargetEdges)"
    Write-Verbose "  App protection policy targets: $($stats.AppProtectionPolicyTargetEdges)"

    # Output to Cosmos DB via output binding
    if ($virtualEdges.Count -gt 0) {
        Push-OutputBinding -Name edgesOut -Value $virtualEdges
        Write-Verbose "Pushed $($virtualEdges.Count) virtual edges to Cosmos DB"
    }

    return @{
        Success = $true
        Statistics = $stats
        DerivedEdgeCount = $virtualEdges.Count
        Timestamp = $timestampFormatted
    }
}
catch {
    $errorMsg = "DeriveVirtualEdges failed: $($_.Exception.Message)"
    Write-Error $errorMsg
    Write-Error $_.ScriptStackTrace
    return @{
        Success = $false
        Error = $errorMsg
        Statistics = $stats
    }
}
#endregion

#region Helper Function - Invoke-CosmosDbQuery
function Invoke-CosmosDbQuery {
    param(
        [string]$Endpoint,
        [string]$Key,
        [string]$DatabaseName,
        [string]$ContainerName,
        [string]$Query,
        [string]$PartitionKey
    )

    $resourceLink = "dbs/$DatabaseName/colls/$ContainerName"
    $uri = "$Endpoint$resourceLink/docs"

    $dateString = [DateTime]::UtcNow.ToString("r")

    # Generate auth signature - Cosmos DB REST API format:
    # StringToSign = verb + "\n" + resourceType + "\n" + resourceLink + "\n" + date + "\n" + ""
    # For POST /dbs/{db}/colls/{coll}/docs: resourceType = "docs", resourceLink = "dbs/{db}/colls/{coll}"
    $keyBytes = [Convert]::FromBase64String($Key)
    $stringToSign = "post`ndocs`n$($resourceLink.ToLower())`n$($dateString.ToLower())`n`n"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))
    $signature = [Convert]::ToBase64String($hashBytes)
    $authHeader = [Uri]::EscapeDataString("type=master&ver=1.0&sig=$signature")

    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date" = $dateString
        "x-ms-version" = "2018-12-31"
        "Content-Type" = "application/query+json"
        "x-ms-documentdb-isquery" = "true"
        "x-ms-documentdb-query-enablecrosspartition" = "true"
    }

    if ($PartitionKey) {
        $headers["x-ms-documentdb-partitionkey"] = "[`"$PartitionKey`"]"
    }

    $body = @{
        query = $Query
    } | ConvertTo-Json

    $results = @()
    $continuationToken = $null

    do {
        if ($continuationToken) {
            $headers["x-ms-continuation"] = $continuationToken
        }

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
            $results += $response.Documents
            $continuationToken = $response.Headers["x-ms-continuation"]
        }
        catch {
            Write-Warning "Cosmos DB query failed: $_"
            break
        }
    } while ($continuationToken)

    return $results
}
#endregion
