<#
.SYNOPSIS
    Derives virtual "gate" edges from Intune policies to their targeted groups
.DESCRIPTION
    Virtual Edge Derivation

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

param($ActivityInput, $compliancePoliciesIn, $appProtectionPoliciesIn)

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

# NOTE: This function uses Cosmos DB input bindings defined in function.json
# - compliancePoliciesIn: Compliance policies from Cosmos
# - appProtectionPoliciesIn: App protection policies from Cosmos

#region Function Logic
try {
    Write-Information "DERIVE-VIRTUAL-DEBUG: === Starting DeriveVirtualEdges ===" -InformationAction Continue

    # Get timestamp from orchestrator
    if ($ActivityInput -and $ActivityInput.Timestamp) {
        $timestamp = $ActivityInput.Timestamp
        Write-Verbose "Using orchestrator timestamp: $timestamp"
    } else {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
        Write-Warning "No orchestrator timestamp - using local: $timestamp"
    }
    $timestampFormatted = $timestamp -replace 'T(\d{2})-(\d{2})-(\d{2})Z', 'T$1:$2:$3Z'

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

    # Use input bindings from function.json instead of REST API queries
    # These are already filtered by policyType and deleted status
    $compliancePolicies = if ($compliancePoliciesIn) { @($compliancePoliciesIn) } else { @() }
    $appProtectionPolicies = if ($appProtectionPoliciesIn) { @($appProtectionPoliciesIn) } else { @() }

    Write-Information "DERIVE-VIRTUAL-DEBUG: Input binding: $($compliancePolicies.Count) compliance policies" -InformationAction Continue
    Write-Information "DERIVE-VIRTUAL-DEBUG: Input binding: $($appProtectionPolicies.Count) app protection policies" -InformationAction Continue

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
                        # Use objectId as id so Cosmos upserts instead of creating duplicates
                        $derivedObjectId = "$($policy.objectId)_$($assignment.groupId)_compliancePolicyTargets"
                        $virtualEdge = @{
                            id = $derivedObjectId
                            objectId = $derivedObjectId
                            edgeType = "compliancePolicyTargets"
                            sourceId = $policy.objectId
                            sourceType = "compliancePolicy"
                            sourceDisplayName = $policy.displayName ?? ""
                            sourcePlatform = $policy.platform ?? ""
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = ""  # Would need group lookup
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
                    # Use objectId as id so Cosmos upserts instead of creating duplicates
                    $derivedObjectId = "$($policy.objectId)_allUsers_compliancePolicyTargets"
                    $virtualEdge = @{
                        id = $derivedObjectId
                        objectId = $derivedObjectId
                        edgeType = "compliancePolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "compliancePolicy"
                        sourceDisplayName = $policy.displayName ?? ""
                        sourcePlatform = $policy.platform ?? ""
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
                    # Use objectId as id so Cosmos upserts instead of creating duplicates
                    $derivedObjectId = "$($policy.objectId)_allDevices_compliancePolicyTargets"
                    $virtualEdge = @{
                        id = $derivedObjectId
                        objectId = $derivedObjectId
                        edgeType = "compliancePolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "compliancePolicy"
                        sourceDisplayName = $policy.displayName ?? ""
                        sourcePlatform = $policy.platform ?? ""
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
                        # Use objectId as id so Cosmos upserts instead of creating duplicates
                        $derivedObjectId = "$($policy.objectId)_$($assignment.groupId)_compliancePolicyExcludes"
                        $virtualEdge = @{
                            id = $derivedObjectId
                            objectId = $derivedObjectId
                            edgeType = "compliancePolicyExcludes"
                            sourceId = $policy.objectId
                            sourceType = "compliancePolicy"
                            sourceDisplayName = $policy.displayName ?? ""
                            sourcePlatform = $policy.platform ?? ""
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = ""
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
                        # Use objectId as id so Cosmos upserts instead of creating duplicates
                        $derivedObjectId = "$($policy.objectId)_$($assignment.groupId)_appProtectionPolicyTargets"
                        $virtualEdge = @{
                            id = $derivedObjectId
                            objectId = $derivedObjectId
                            edgeType = "appProtectionPolicyTargets"
                            sourceId = $policy.objectId
                            sourceType = "appProtectionPolicy"
                            sourceDisplayName = $policy.displayName ?? ""
                            sourcePlatform = $policy.platform ?? ""
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = ""
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
                    # Use objectId as id so Cosmos upserts instead of creating duplicates
                    $derivedObjectId = "$($policy.objectId)_allUsers_appProtectionPolicyTargets"
                    $virtualEdge = @{
                        id = $derivedObjectId
                        objectId = $derivedObjectId
                        edgeType = "appProtectionPolicyTargets"
                        sourceId = $policy.objectId
                        sourceType = "appProtectionPolicy"
                        sourceDisplayName = $policy.displayName ?? ""
                        sourcePlatform = $policy.platform ?? ""
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
                        # Use objectId as id so Cosmos upserts instead of creating duplicates
                        $derivedObjectId = "$($policy.objectId)_$($assignment.groupId)_appProtectionPolicyExcludes"
                        $virtualEdge = @{
                            id = $derivedObjectId
                            objectId = $derivedObjectId
                            edgeType = "appProtectionPolicyExcludes"
                            sourceId = $policy.objectId
                            sourceType = "appProtectionPolicy"
                            sourceDisplayName = $policy.displayName ?? ""
                            sourcePlatform = $policy.platform ?? ""
                            targetId = $assignment.groupId
                            targetType = "group"
                            targetDisplayName = ""
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
    Write-Information "DERIVE-VIRTUAL-DEBUG: Derived $($stats.TotalDerived) virtual edges total" -InformationAction Continue
    Write-Information "DERIVE-VIRTUAL-DEBUG: Compliance policy targets: $($stats.CompliancePolicyTargetEdges)" -InformationAction Continue
    Write-Information "DERIVE-VIRTUAL-DEBUG: App protection policy targets: $($stats.AppProtectionPolicyTargetEdges)" -InformationAction Continue

    # Output to Cosmos DB via output binding
    if ($virtualEdges.Count -gt 0) {
        Write-Information "DERIVE-VIRTUAL-DEBUG: Pushing $($virtualEdges.Count) edges to Cosmos output binding" -InformationAction Continue
        Push-OutputBinding -Name edgesOut -Value $virtualEdges
        Write-Information "DERIVE-VIRTUAL-DEBUG: Push complete!" -InformationAction Continue
    } else {
        Write-Warning "DERIVE-VIRTUAL-WARNING: No virtual edges to push - check if policies have assignments"
    }

    Write-Information "DERIVE-VIRTUAL-DEBUG: === DeriveVirtualEdges Complete ===" -InformationAction Continue
    return @{
        Success = $true
        Statistics = $stats
        DerivedEdgeCount = $virtualEdges.Count
        Timestamp = $timestampFormatted
    }
}
catch {
    $errorMsg = "DeriveVirtualEdges failed: $($_.Exception.Message)"
    Write-Error "DERIVE-VIRTUAL-ERROR: $errorMsg"
    Write-Error "DERIVE-VIRTUAL-ERROR: Stack: $($_.ScriptStackTrace)"
    return @{
        Success = $false
        Error = $errorMsg
        Statistics = $stats
    }
}
#endregion
