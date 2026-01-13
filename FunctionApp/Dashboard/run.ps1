using namespace System.Net

# Dashboard - 5 Unified Containers + Derived Edges
# 1. principals (users, groups, SPs, devices)
# 2. resources (applications + Azure resources)
# 3. edges (all relationships + derived edges)
# 4. policies (CA, Intune compliance, App Protection, Named Locations)
# 5. audit (change tracking)

# Azure Functions runtime passes these parameters - not all are used in this function
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Request', Justification = 'Required by Azure Functions runtime')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TriggerMetadata', Justification = 'Required by Azure Functions runtime')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'eventsIn', Justification = 'Events container binding kept for future use')]
param(
    $Request,
    $TriggerMetadata,
    $principalsIn,
    $resourcesIn,
    $edgesIn,
    $policiesIn,
    $eventsIn,
    $auditIn
)

Add-Type -AssemblyName System.Web

function Format-Value {
    param($value, $maxLen = 200)
    if ($null -eq $value) { return '<span style="color:#999;font-style:italic">null</span>' }
    if ($value -is [string] -and $value -eq '') { return '<span style="color:#999;font-style:italic">-</span>' }
    if ($value -is [bool]) { if ($value) { return '<span style="color:#107c10">true</span>' } else { return '<span style="color:#d13438">false</span>' } }
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return '[]' }
        # For arrays, try to show content up to maxLen
        try {
            $json = $value | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue
            if ($json.Length -gt $maxLen) { $json = $json.Substring(0, $maxLen) + "..." }
            return '<span title="' + [System.Web.HttpUtility]::HtmlAttributeEncode($json) + '">[' + $value.Count + ' items]</span>'
        } catch {
            return "[$($value.Count) items]"
        }
    }
    if ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject] -or $value.GetType().Name -match 'Hashtable|OrderedDictionary') {
        # Convert to JSON for readable display
        try {
            $json = $value | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue
            $display = if ($json.Length -gt $maxLen) { $json.Substring(0, $maxLen) + "..." } else { $json }
            # Show abbreviated version with full content on hover
            return '<span title="' + [System.Web.HttpUtility]::HtmlAttributeEncode($json) + '">' + [System.Web.HttpUtility]::HtmlEncode($display) + '</span>'
        } catch {
            return '{object}'
        }
    }
    $str = $value.ToString()
    if ($str.Length -gt $maxLen) { $str = $str.Substring(0, $maxLen) + "..." }
    return [System.Web.HttpUtility]::HtmlEncode($str)
}

# Dynamically discover all columns from data, with priority columns first
# Priority columns are always shown (even if all null), other columns only shown if they have data
function Get-AllColumns {
    param($data, $priorityColumns = @())
    if ($null -eq $data -or $data.Count -eq 0) { return $priorityColumns }

    # Collect property names that have at least one non-null value
    $propsWithValues = @{}
    foreach ($item in $data) {
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in $item.Keys) {
                if ($null -ne $item[$key]) { $propsWithValues[$key] = $true }
            }
        } else {
            foreach ($prop in $item.PSObject.Properties) {
                if ($null -ne $prop.Value) { $propsWithValues[$prop.Name] = $true }
            }
        }
    }

    # Build column list: priority columns ALWAYS first, then the rest alphabetically
    $result = @()
    foreach ($col in $priorityColumns) {
        $result += $col
        $propsWithValues.Remove($col)  # Remove from remaining to avoid duplicates
    }
    # Add remaining columns alphabetically, excluding internal Cosmos fields, common noise, and soft-delete implementation details
    $excludeFields = @('_rid', '_self', '_etag', '_attachments', '_ts', 'id', 'principalType', 'resourceType', 'edgeType', 'policyType', 'eventType', 'deleted', 'deletedTimestamp', 'effectiveTo', 'ttl')
    $remaining = $propsWithValues.Keys | Where-Object { $_ -notin $excludeFields -and $_ -notin $priorityColumns } | Sort-Object
    $result += $remaining

    return $result
}

function Build-Table {
    param($data, $tableId, $columns, $entityType = $null, $parentCount = $null)
    # Build headers - always show column headers even for empty data
    $headers = ($columns | ForEach-Object { "<th onclick=`"sortTable('$tableId', $($columns.IndexOf($_)))`">$_</th>" }) -join ""

    if ($null -eq $data -or $data.Count -eq 0) {
        # Show table with headers but empty message in body
        $emptyMsg = if ($parentCount -eq 0) {
            'No data in container - collection may not have run yet'
        } elseif ($parentCount -gt 0) {
            "No $entityType found (0 of $parentCount in container)"
        } else {
            'No data'
        }
        $emptyRow = "<tr><td colspan='$($columns.Count)' style='text-align:center;color:#666;padding:20px;font-size:0.85em;'>$emptyMsg</td></tr>"
        return "<table id='$tableId'><thead><tr>$headers</tr></thead><tbody>$emptyRow</tbody></table><div id='$tableId-pager' class='pager'></div>"
    }

    $rows = ($data | ForEach-Object {
        $item = $_
        $cells = ($columns | ForEach-Object {
            $val = if ($item -is [System.Collections.IDictionary]) { $item[$_] } else { $item.$_ }
            "<td>$(Format-Value $val)</td>"
        }) -join ""
        "<tr>$cells</tr>"
    }) -join "`n"

    return "<table id='$tableId'><thead><tr>$headers</tr></thead><tbody>$rows</tbody></table><div id='$tableId-pager' class='pager'></div>"
}

try {
    # ========== CONTAINER 1: PRINCIPALS (users, groups, SPs, devices) ==========
    $allPrincipals = @($principalsIn | Where-Object { $_ })
    $users = @($allPrincipals | Where-Object { $_.principalType -eq 'user' })
    $groups = @($allPrincipals | Where-Object { $_.principalType -eq 'group' })
    $sps = @($allPrincipals | Where-Object { $_.principalType -eq 'servicePrincipal' })
    $devices = @($allPrincipals | Where-Object { $_.principalType -eq 'device' })
    $adminUnits = @($allPrincipals | Where-Object { $_.principalType -eq 'administrativeUnit' })

    # ========== CONTAINER 2: RESOURCES (applications + Azure resources + role definitions) ==========
    $allResources = @($resourcesIn | Where-Object { $_ })
    $apps = @($allResources | Where-Object { $_.resourceType -eq 'application' })
    $tenants = @($allResources | Where-Object { $_.resourceType -eq 'tenant' })
    $mgmtGroups = @($allResources | Where-Object { $_.resourceType -eq 'managementGroup' })
    $subscriptions = @($allResources | Where-Object { $_.resourceType -eq 'subscription' })

    # Enrich subscriptions with owner info from Azure RBAC edges
    # Owner role GUID: 8e3af657-a8ff-443c-a75c-2fe8c4bcb635
    $subscriptionOwners = @{}
    foreach ($edge in $edgesIn) {
        if ($null -eq $edge) { continue }
        if ($edge.edgeType -eq 'azureRbac' -and
            $edge.scopeType -eq 'subscription' -and
            $edge.targetRoleDefinitionId -and
            $edge.targetRoleDefinitionId -match '8e3af657-a8ff-443c-a75c-2fe8c4bcb635') {
            # Get subscription ID - prefer subscriptionId field, fall back to extracting from scope
            $subId = $edge.subscriptionId
            if (-not $subId -and $edge.scope -match '/subscriptions/([a-f0-9-]+)') {
                $subId = $Matches[1]
            }
            if (-not $subId) { continue }
            if (-not $subscriptionOwners.ContainsKey($subId)) {
                $subscriptionOwners[$subId] = @()
            }
            # Look up principal displayName
            $principalName = $edge.sourceDisplayName
            if (-not $principalName) {
                $principal = $allPrincipals | Where-Object { $_.objectId -eq $edge.sourceId } | Select-Object -First 1
                $principalName = if ($principal) { $principal.displayName ?? $principal.userPrincipalName ?? $edge.sourceId } else { $edge.sourceId }
            }
            $ownerInfo = "$principalName ($($edge.sourceType))"
            if ($ownerInfo -notin $subscriptionOwners[$subId]) {
                $subscriptionOwners[$subId] += $ownerInfo
            }
        }
    }
    # Add owners property to each subscription
    # Create deep copies to ensure mutability (Cosmos DB objects may be read-only)
    $enrichedSubscriptions = @()
    foreach ($sub in $subscriptions) {
        if ($null -eq $sub) { continue }
        $subId = $sub.subscriptionId ?? $sub.objectId
        # If objectId has path prefix, extract just the GUID
        if ($subId -match '/subscriptions/([a-f0-9-]+)') {
            $subId = $Matches[1]
        }
        # Convert to JSON and back to create a mutable deep copy
        $subCopy = $sub | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        # Add owners property
        $ownerValue = if ($subId -and $subscriptionOwners.ContainsKey($subId)) {
            ($subscriptionOwners[$subId] -join ', ')
        } else {
            $null
        }
        $subCopy | Add-Member -NotePropertyName 'owners' -NotePropertyValue $ownerValue -Force
        $enrichedSubscriptions += $subCopy
    }
    $subscriptions = $enrichedSubscriptions

    $resourceGroups = @($allResources | Where-Object { $_.resourceType -eq 'resourceGroup' })
    $keyVaults = @($allResources | Where-Object { $_.resourceType -eq 'keyVault' })
    $vms = @($allResources | Where-Object { $_.resourceType -eq 'virtualMachine' })
    $automationAccounts = @($allResources | Where-Object { $_.resourceType -eq 'automationAccount' })
    $functionApps = @($allResources | Where-Object { $_.resourceType -eq 'functionApp' })
    $logicApps = @($allResources | Where-Object { $_.resourceType -eq 'logicApp' })
    $webApps = @($allResources | Where-Object { $_.resourceType -eq 'webApp' })
    # Additional Azure resources
    $storageAccounts = @($allResources | Where-Object { $_.resourceType -eq 'storageAccount' })
    $aksClusters = @($allResources | Where-Object { $_.resourceType -eq 'aksCluster' })
    $containerRegistries = @($allResources | Where-Object { $_.resourceType -eq 'containerRegistry' })
    $vmScaleSets = @($allResources | Where-Object { $_.resourceType -eq 'vmScaleSet' })
    $dataFactories = @($allResources | Where-Object { $_.resourceType -eq 'dataFactory' })

    # ========== CONTAINER 3: EDGES (all relationships + derived edges) ==========
    $allEdges = @($edgesIn | Where-Object { $_ })

    # Build principal lookup table for edge enrichment
    $principalLookup = @{}
    foreach ($principal in $allPrincipals) {
        if ($principal.objectId) {
            $principalLookup[$principal.objectId] = @{
                displayName = $principal.displayName ?? $principal.userPrincipalName ?? $principal.objectId
                principalType = $principal.principalType ?? ''
            }
        }
    }

    # Enrich edges that have empty sourceDisplayName (Azure RBAC, Directory Roles, PIM)
    $enrichedEdges = @()
    foreach ($edge in $allEdges) {
        if ($null -eq $edge) { continue }
        # If sourceDisplayName is empty and we have the principal in our lookup, enrich it
        if ((-not $edge.sourceDisplayName -or $edge.sourceDisplayName -eq '') -and $edge.sourceId -and $principalLookup.ContainsKey($edge.sourceId)) {
            $edgeCopy = $edge | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $edgeCopy.sourceDisplayName = $principalLookup[$edge.sourceId].displayName
            if (-not $edgeCopy.sourceType -or $edgeCopy.sourceType -eq '') {
                $edgeCopy.sourceType = $principalLookup[$edge.sourceId].principalType
            }
            $enrichedEdges += $edgeCopy
        } else {
            $enrichedEdges += $edge
        }
    }
    $allEdges = $enrichedEdges

    $groupMembers = @($allEdges | Where-Object { $_.edgeType -match '^groupMember' })
    $directoryRoles = @($allEdges | Where-Object { $_.edgeType -eq 'directoryRole' })
    $pimRoles = @($allEdges | Where-Object { $_.edgeType -match '^pim(Eligible|Active)$' })
    $pimGroups = @($allEdges | Where-Object { $_.edgeType -match '^pimGroup' })
    $azureRbac = @($allEdges | Where-Object { $_.edgeType -eq 'azureRbac' -or $_.edgeType -eq 'azureRoleAssignment' })
    $appRoles = @($allEdges | Where-Object { $_.edgeType -eq 'appRoleAssignment' })
    $owners = @($allEdges | Where-Object { $_.edgeType -match 'Owner$' })
    $licenses = @($allEdges | Where-Object { $_.edgeType -eq 'license' })
    $contains = @($allEdges | Where-Object { $_.edgeType -eq 'contains' })
    $kvAccess = @($allEdges | Where-Object { $_.edgeType -eq 'keyVaultAccess' })
    $managedIdentities = @($allEdges | Where-Object { $_.edgeType -eq 'hasManagedIdentity' })
    $auMembers = @($allEdges | Where-Object { $_.edgeType -eq 'auMember' })
    $auScopedRoles = @($allEdges | Where-Object { $_.edgeType -eq 'auScopedRole' })
    # Additional edge types that were being collected but not displayed
    $pimRequests = @($allEdges | Where-Object { $_.edgeType -eq 'pimRequest' })
    $oauth2Grants = @($allEdges | Where-Object { $_.edgeType -eq 'oauth2PermissionGrant' })
    $rolePolicyAssignments = @($allEdges | Where-Object { $_.edgeType -eq 'rolePolicyAssignment' })
    # Derived edges (from DeriveEdges function)
    $derivedEdges = @($allEdges | Where-Object { $_.edgeType -match '^can|^is|^azure' -and $_.derivedFrom })
    # CA policy edges (caPolicyTargetsPrincipal, caPolicyTargetsApplication, caPolicyExcludesPrincipal, etc.)
    $caPolicyEdges = @($allEdges | Where-Object { $_.edgeType -match '^caPolicy' })
    # Virtual edges (Intune policy targeting - compliancePolicyTargets, appProtectionPolicyTargets)
    $virtualEdges = @($allEdges | Where-Object { $_.edgeType -match 'compliancePolicy|appProtectionPolicy' })

    # ========== CONTAINER 4: POLICIES ==========
    $allPolicies = @($policiesIn | Where-Object { $_ })
    $caPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'conditionalAccess' })
    $rolePolicies = @($allPolicies | Where-Object { $_.policyType -match 'roleManagement' })
    # Intune policies
    $compliancePolicies = @($allPolicies | Where-Object { $_.policyType -eq 'compliancePolicy' })
    $appProtectionPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'appProtectionPolicy' })
    $namedLocations = @($allPolicies | Where-Object { $_.policyType -eq 'namedLocation' })
    # Security policies (Auth Methods, Security Defaults, Authorization)
    $authMethodsPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'authenticationMethodsPolicy' })
    $securityDefaultsPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'securityDefaults' })
    $authorizationPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'authorizationPolicy' })
    # B2B, Consent, Token policies
    $crossTenantPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'crossTenantAccessPolicy' })
    $permissionGrantPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'permissionGrantPolicy' })
    $adminConsentPolicies = @($allPolicies | Where-Object { $_.policyType -eq 'adminConsentRequestPolicy' })

    # ========== CONTAINER 5: AUDIT (Change Tracking) ==========
    $changes = @($auditIn | Where-Object { $_ })
    # Filter changes by entity type for sub-tabs
    $principalChanges = @($changes | Where-Object { $_.entityType -eq 'principals' })
    $policyChanges = @($changes | Where-Object { $_.entityType -eq 'policies' })
    $resourceChanges = @($changes | Where-Object { $_.entityType -eq 'resources' })
    $edgeChanges = @($changes | Where-Object { $_.entityType -eq 'edges' })

    # ========== DEBUG METRICS ==========
    # Calculate data freshness from collection timestamps
    $allTimestamps = @()
    foreach ($item in @($allPrincipals + $allResources + $allPolicies)) {
        if ($item.collectionTimestamp) {
            try { $allTimestamps += [DateTime]::Parse($item.collectionTimestamp) } catch {}
        }
    }
    $newestCollection = if ($allTimestamps.Count -gt 0) { ($allTimestamps | Sort-Object -Descending | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
    $oldestCollection = if ($allTimestamps.Count -gt 0) { ($allTimestamps | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
    $dataAgeMinutes = if ($allTimestamps.Count -gt 0) { [math]::Round(((Get-Date) - ($allTimestamps | Sort-Object -Descending | Select-Object -First 1)).TotalMinutes, 1) } else { 'N/A' }

    # Audit change type breakdown
    $newCount = @($changes | Where-Object { $_.changeType -eq 'new' }).Count
    $modifiedCount = @($changes | Where-Object { $_.changeType -eq 'modified' }).Count
    $deletedCount = @($changes | Where-Object { $_.changeType -eq 'deleted' }).Count

    # Data quality checks
    $usersNoUpn = @($users | Where-Object { -not $_.userPrincipalName }).Count
    $groupsNoName = @($groups | Where-Object { -not $_.displayName }).Count
    $edgesNoSource = @($allEdges | Where-Object { -not $_.sourceId }).Count
    $edgesNoTarget = @($allEdges | Where-Object { -not $_.targetId }).Count

    # Column definitions - priority columns shown first, then ALL other columns discovered dynamically
    # Dynamic column discovery ensures all collected properties are visible
    $userPriority = @('objectId', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'perUserMfaState', 'authMethodCount', 'riskLevel', 'riskState', 'riskLastUpdatedDateTime', 'isAtRisk', 'hasP2License', 'hasE5License', 'licenseCount', 'assignedLicenseSkus', 'mail', 'jobTitle', 'department', 'createdDateTime', 'lastPasswordChangeDateTime', 'onPremisesSyncEnabled')
    $groupPriority = @('objectId', 'displayName', 'securityEnabled', 'groupTypes', 'groupTypeCategory', 'memberCountDirect', 'memberCountIndirect', 'memberCountTotal', 'userMemberCount', 'groupMemberCount', 'servicePrincipalMemberCount', 'deviceMemberCount', 'nestingDepth', 'isAssignableToRole', 'mail', 'visibility', 'createdDateTime', 'onPremisesSyncEnabled')
    $spPriority = @('objectId', 'displayName', 'appId', 'servicePrincipalType', 'accountEnabled', 'secretCount', 'certificateCount', 'createdDateTime', 'appOwnerOrganizationId')
    $devicePriority = @('objectId', 'displayName', 'deviceId', 'operatingSystem', 'operatingSystemVersion', 'isCompliant', 'isManaged', 'trustType', 'intunePrimaryUser', 'usersLoggedOn', 'registrationDateTime', 'approximateLastSignInDateTime')
    $adminUnitPriority = @('objectId', 'displayName', 'description', 'membershipType', 'memberCountTotal', 'userMemberCount', 'groupMemberCount', 'deviceMemberCount', 'scopedRoleCount', 'membershipRule', 'isMemberManagementRestricted', 'visibility')
    $appPriority = @('objectId', 'displayName', 'appId', 'signInAudience', 'secretCount', 'certificateCount', 'createdDateTime', 'publisherDomain')
    $azureResPriority = @('objectId', 'displayName', 'resourceType', 'owners', 'location', 'subscriptionId', 'resourceGroup', 'kind', 'sku')
    $edgePriority = @('id', 'sourceId', 'sourceDisplayName', 'edgeType', 'targetId', 'targetDisplayName', 'effectiveFrom', 'effectiveTo')
    $derivedEdgePriority = @('id', 'sourceId', 'sourceDisplayName', 'edgeType', 'targetId', 'targetDisplayName', 'derivedFrom', 'severity', 'capability')
    # Azure RBAC-specific columns with role name prominently displayed
    $azureRbacPriority = @('sourceDisplayName', 'sourceType', 'targetRoleDefinitionName', 'scope', 'scopeType', 'subscriptionName', 'resourceGroup', 'sourceId', 'targetRoleDefinitionId')
    $policyPriority = @('objectId', 'displayName', 'policyType', 'state', 'createdDateTime', 'modifiedDateTime')
    $intunePolicyPriority = @('objectId', 'displayName', 'policyType', 'platform', 'createdDateTime', 'lastModifiedDateTime')
    $namedLocPriority = @('objectId', 'displayName', 'policyType', 'locationType', 'isTrusted', 'createdDateTime')
    # Security policy column priorities
    $authMethodsPriority = @('objectId', 'displayName', 'policyType', 'methodConfigurationCount', 'microsoftAuthenticatorEnabled', 'fido2Enabled', 'smsEnabled', 'temporaryAccessPassEnabled', 'policyMigrationState', 'lastModifiedDateTime')
    $securityDefaultsPriority = @('objectId', 'displayName', 'policyType', 'isEnabled', 'description')
    $authorizationPriority = @('objectId', 'displayName', 'policyType', 'guestUserRoleName', 'allowInvitesFrom', 'usersCanCreateApps', 'usersCanCreateGroups', 'usersCanCreateTenants', 'blockMsolPowerShell')
    # B2B, Consent, Token policy column priorities
    $crossTenantPriority = @('objectId', 'displayName', 'policyType', 'allowedCloudEndpoints', 'default')
    $permissionGrantPriority = @('objectId', 'displayName', 'policyType', 'includeCount', 'excludeCount', 'includes', 'excludes')
    $adminConsentPriority = @('objectId', 'displayName', 'policyType', 'isEnabled', 'notifyReviewers', 'remindersEnabled', 'requestDurationInDays', 'reviewerCount')
    $auditPriority = @('objectId', 'entityType', 'changeType', 'displayName', 'changeTimestamp', 'auditDate', 'changedFields', 'delta')

    # Dynamically get ALL columns from data, with priority columns first
    $userCols = Get-AllColumns $users $userPriority
    $groupCols = Get-AllColumns $groups $groupPriority
    $spCols = Get-AllColumns $sps $spPriority
    $deviceCols = Get-AllColumns $devices $devicePriority
    $adminUnitCols = Get-AllColumns $adminUnits $adminUnitPriority
    $appCols = Get-AllColumns $apps $appPriority
    $azureResCols = Get-AllColumns (@($tenants + $mgmtGroups + $subscriptions + $resourceGroups + $keyVaults + $vms + $storageAccounts + $aksClusters + $containerRegistries + $vmScaleSets + $functionApps + $logicApps + $webApps + $automationAccounts + $dataFactories) | Where-Object { $_ }) $azureResPriority
    # Subscription-specific columns (includes owners)
    $subsPriority = @('objectId', 'displayName', 'owners', 'subscriptionId', 'state', 'authorizationSource', 'tenantId')
    $subsCols = Get-AllColumns $subscriptions $subsPriority
    $edgeCols = Get-AllColumns $allEdges $edgePriority
    $derivedEdgeCols = Get-AllColumns $derivedEdges $derivedEdgePriority
    $azureRbacCols = Get-AllColumns $azureRbac $azureRbacPriority
    $policyCols = Get-AllColumns $caPolicies $policyPriority
    $intunePolicyCols = Get-AllColumns (@($compliancePolicies + $appProtectionPolicies) | Where-Object { $_ }) $intunePolicyPriority
    $namedLocCols = Get-AllColumns $namedLocations $namedLocPriority
    # Security policy columns
    $authMethodsCols = Get-AllColumns $authMethodsPolicies $authMethodsPriority
    $securityDefaultsCols = Get-AllColumns $securityDefaultsPolicies $securityDefaultsPriority
    $authorizationCols = Get-AllColumns $authorizationPolicies $authorizationPriority
    # B2B, Consent, Token policy columns
    $crossTenantCols = Get-AllColumns $crossTenantPolicies $crossTenantPriority
    $permissionGrantCols = Get-AllColumns $permissionGrantPolicies $permissionGrantPriority
    $adminConsentCols = Get-AllColumns $adminConsentPolicies $adminConsentPriority
    $auditCols = Get-AllColumns $changes $auditPriority

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Debug Dashboard - Entra Risk</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f0f2f5; }
        h1 { color: #0078d4; margin: 0 0 15px 0; }
        .summary { background: #e3f2fd; padding: 12px 15px; border-radius: 6px; margin-bottom: 20px; border-left: 4px solid #0078d4; font-size: 0.9em; }
        .container { background: white; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .container-header { background: #0078d4; color: white; padding: 12px 20px; border-radius: 8px 8px 0 0; font-weight: bold; display: flex; align-items: center; gap: 10px; cursor: pointer; user-select: none; }
        .container-header:hover { background: #106ebe; }
        .container-header .chevron { transition: transform 0.2s; margin-right: 5px; }
        .container.collapsed .chevron { transform: rotate(-90deg); }
        .container.collapsed .container-header { border-radius: 8px; }
        .container-header .count { background: rgba(255,255,255,0.2); padding: 2px 8px; border-radius: 10px; font-size: 0.85em; }
        .container-header .desc { font-weight: normal; opacity: 0.85; font-size: 0.9em; margin-left: auto; }
        .container-body { overflow: hidden; transition: max-height 0.3s ease-out; }
        .container.collapsed .container-body { max-height: 0 !important; }
        .tabs { display: flex; flex-wrap: wrap; gap: 3px; padding: 10px 15px; background: #f8f9fa; border-bottom: 1px solid #e9ecef; }
        .tab { padding: 6px 12px; border: none; background: #e9ecef; cursor: pointer; border-radius: 4px; font-size: 0.85em; }
        .tab:hover { background: #dee2e6; }
        .tab.active { background: #0078d4; color: white; }
        .tab.derived { background: #ff8c00; color: white; }
        .tab.derived:hover { background: #e67e00; }
        .tab-content { display: none; padding: 0; overflow-x: auto; max-height: 600px; overflow-y: auto; }
        .tab-content.active { display: block; }
        table { width: max-content; min-width: 100%; border-collapse: collapse; font-size: 0.8em; }
        th { background: #f8f9fa; padding: 10px 8px; text-align: left; border-bottom: 2px solid #dee2e6; cursor: pointer; white-space: nowrap; font-weight: 600; position: sticky; top: 0; z-index: 1; }
        th:hover { background: #e9ecef; }
        td { padding: 8px; border-bottom: 1px solid #f0f0f0; white-space: nowrap; max-width: 300px; overflow: hidden; text-overflow: ellipsis; }
        tr:hover { background: #f8f9fa; }
        .risk-high { color: #d13438; font-weight: bold; }
        .risk-medium { color: #ff8c00; font-weight: bold; }
        .risk-low { color: #107c10; }
        .export-btns { float: right; margin-left: 10px; }
        .export-btn { padding: 4px 8px; margin-left: 4px; font-size: 11px; cursor: pointer; background: #f0f0f0; border: 1px solid #ccc; border-radius: 3px; }
        .export-btn:hover { background: #e0e0e0; }
        .pager { padding: 8px 10px; background: #f8f9fa; border-top: 1px solid #dee2e6; font-size: 0.8em; display: flex; align-items: center; gap: 5px; }
        .pager button { padding: 4px 8px; border: 1px solid #ccc; background: #fff; cursor: pointer; border-radius: 3px; }
        .pager button:hover:not(:disabled) { background: #e9ecef; }
        .pager button:disabled { opacity: 0.5; cursor: not-allowed; }
        .page-size-select { margin-left: auto; }
        .page-size-select select { padding: 3px 6px; border: 1px solid #ccc; border-radius: 3px; }
    </style>
    <script>
        function toggleContainer(containerId) {
            var container = document.getElementById(containerId);
            container.classList.toggle('collapsed');
        }
        function showTab(container, tabId, btn) {
            document.querySelectorAll('#' + container + ' .tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('#' + container + ' .tab').forEach(b => b.classList.remove('active'));
            document.getElementById(tabId).classList.add('active');
            btn.classList.add('active');
        }
        function sortTable(tableId, col) {
            var table = document.getElementById(tableId);
            if (!table) return;
            var rows = Array.from(table.querySelectorAll('tbody tr'));
            var asc = table.dataset.sortCol != col || table.dataset.sortDir != 'asc';
            rows.sort((a, b) => {
                var av = a.cells[col]?.textContent || '';
                var bv = b.cells[col]?.textContent || '';
                return asc ? av.localeCompare(bv) : bv.localeCompare(av);
            });
            rows.forEach(r => table.querySelector('tbody').appendChild(r));
            table.dataset.sortCol = col;
            table.dataset.sortDir = asc ? 'asc' : 'desc';
        }
        function getTableData(tableId) {
            var table = document.getElementById(tableId);
            if (!table) return { headers: [], rows: [] };
            var headers = Array.from(table.querySelectorAll('thead th')).map(th => th.textContent.trim());
            var rows = Array.from(table.querySelectorAll('tbody tr')).map(tr =>
                Array.from(tr.cells).map(td => td.textContent.trim())
            );
            return { headers, rows };
        }
        function exportToCSV(tableId, prefix) {
            var data = getTableData(tableId);
            if (data.rows.length === 0) { alert('No data to export'); return; }
            var tabName = tableId.replace('-tbl', '');
            var filename = prefix + '-' + tabName;
            var csv = [data.headers.map(h => '"' + h.replace(/"/g, '""') + '"').join(',')];
            data.rows.forEach(row => {
                csv.push(row.map(cell => '"' + cell.replace(/"/g, '""') + '"').join(','));
            });
            downloadFile(csv.join('\n'), filename + '.csv', 'text/csv');
        }
        function exportToJSON(tableId, prefix) {
            var data = getTableData(tableId);
            if (data.rows.length === 0) { alert('No data to export'); return; }
            var tabName = tableId.replace('-tbl', '');
            var filename = prefix + '-' + tabName;
            var json = data.rows.map(row => {
                var obj = {};
                data.headers.forEach((h, i) => obj[h] = row[i]);
                return obj;
            });
            downloadFile(JSON.stringify(json, null, 2), filename + '.json', 'application/json');
        }
        function downloadFile(content, filename, mimeType) {
            var blob = new Blob([content], { type: mimeType });
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = filename;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        }
        // Pagination
        var pageSize = 50;
        var currentPages = {};
        function initPagination(tableId) {
            var table = document.getElementById(tableId);
            if (!table) return;
            var rows = table.querySelectorAll('tbody tr');
            var total = rows.length;
            if (total <= pageSize) {
                // No pagination needed for small tables
                var pager = document.getElementById(tableId + '-pager');
                if (pager) pager.style.display = 'none';
                return;
            }
            currentPages[tableId] = 1;
            showPage(tableId, 1);
            updatePager(tableId, total);
        }
        function showPage(tableId, page) {
            var table = document.getElementById(tableId);
            if (!table) return;
            var rows = Array.from(table.querySelectorAll('tbody tr'));
            var total = rows.length;
            var totalPages = Math.ceil(total / pageSize);
            if (page < 1) page = 1;
            if (page > totalPages) page = totalPages;
            currentPages[tableId] = page;
            var start = (page - 1) * pageSize;
            var end = start + pageSize;
            rows.forEach((row, i) => {
                row.style.display = (i >= start && i < end) ? '' : 'none';
            });
            updatePager(tableId, total);
        }
        function updatePager(tableId, total) {
            var pager = document.getElementById(tableId + '-pager');
            if (!pager) return;
            var page = currentPages[tableId] || 1;
            var totalPages = Math.ceil(total / pageSize);
            var start = (page - 1) * pageSize + 1;
            var end = Math.min(page * pageSize, total);
            pager.innerHTML = '<span>Showing ' + start + '-' + end + ' of ' + total + '</span> ' +
                '<button onclick="showPage(\'' + tableId + '\', 1)" ' + (page===1?'disabled':'') + '>&laquo;</button> ' +
                '<button onclick="showPage(\'' + tableId + '\', ' + (page-1) + ')" ' + (page===1?'disabled':'') + '>&lsaquo;</button> ' +
                '<span style="margin:0 8px;">Page ' + page + ' / ' + totalPages + '</span>' +
                '<button onclick="showPage(\'' + tableId + '\', ' + (page+1) + ')" ' + (page===totalPages?'disabled':'') + '>&rsaquo;</button> ' +
                '<button onclick="showPage(\'' + tableId + '\', ' + totalPages + ')" ' + (page===totalPages?'disabled':'') + '>&raquo;</button>';
            pager.style.display = totalPages > 1 ? 'block' : 'none';
        }
        function changePageSize(newSize) {
            pageSize = parseInt(newSize);
            Object.keys(currentPages).forEach(function(tableId) {
                currentPages[tableId] = 1;
                var table = document.getElementById(tableId);
                if (table) {
                    var total = table.querySelectorAll('tbody tr').length;
                    showPage(tableId, 1);
                }
            });
        }
        // Initialize pagination on load
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('table').forEach(function(table) {
                if (table.id) initPagination(table.id);
            });
        });
    </script>
</head>
<body>
    <h1>Debug Dashboard <small style="font-size:0.5em;color:#666;">(Entra Risk v3.5)</small></h1>
    <div class="summary">
        <b>Container Counts</b> |
        Principals: <b>$($allPrincipals.Count)</b> (U:$($users.Count) G:$($groups.Count) SP:$($sps.Count) D:$($devices.Count) AU:$($adminUnits.Count)) |
        Resources: <b>$($allResources.Count)</b> |
        Edges: <b>$($allEdges.Count)</b> (Derived: $($derivedEdges.Count)) |
        Policies: <b>$($allPolicies.Count)</b> |
        Audit: <b>$($changes.Count)</b>
    </div>
    <div class="summary" style="background:#fff3cd;border-left-color:#ffc107;">
        <b>Debug Metrics</b> |
        Data Age: <b>$dataAgeMinutes min</b> |
        Newest: $newestCollection |
        Oldest: $oldestCollection |
        Changes: <span style="color:#107c10">+$newCount new</span> / <span style="color:#0078d4">~$modifiedCount mod</span> / <span style="color:#d13438">-$deletedCount del</span>
        $(if ($usersNoUpn -gt 0 -or $groupsNoName -gt 0 -or $edgesNoSource -gt 0 -or $edgesNoTarget -gt 0) {
            " | <b style='color:#d13438'>Quality Issues:</b> " +
            $(if ($usersNoUpn -gt 0) { "Users w/o UPN: $usersNoUpn " } else { "" }) +
            $(if ($groupsNoName -gt 0) { "Groups w/o name: $groupsNoName " } else { "" }) +
            $(if ($edgesNoSource -gt 0) { "Edges w/o source: $edgesNoSource " } else { "" }) +
            $(if ($edgesNoTarget -gt 0) { "Edges w/o target: $edgesNoTarget" } else { "" })
        })
    </div>
    <div class="summary" style="background:#e8f5e9;border-left-color:#4caf50;">
        <b>View Generated</b>: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC |
        <span class="page-size-select">Rows per page: <select onchange="changePageSize(this.value)">
            <option value="25">25</option>
            <option value="50" selected>50</option>
            <option value="100">100</option>
            <option value="250">250</option>
        </select></span>
    </div>
    $(if ($allPrincipals.Count -ge 1000 -or $allEdges.Count -ge 2000 -or $allResources.Count -ge 500) {
        '<div class="summary" style="background:#ffebee;border-left-color:#d32f2f;"><b>Data Truncated</b>: Some containers exceeded display limits. ' +
        "Principals: $($allPrincipals.Count)/1000, Edges: $($allEdges.Count)/2000, Resources: $($allResources.Count)/500. " +
        'Use export or direct Cosmos queries for full data.</div>'
    })

    <!-- CONTAINER 1: PRINCIPALS -->
    <div class="container" id="principals-section">
        <div class="container-header" onclick="toggleContainer('principals-section')">
            <span class="chevron">&#9660;</span>
            PRINCIPALS <span class="count">$($allPrincipals.Count)</span>
            <span class="desc">users (with risk), groups, service principals, devices</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('principals-section', 'users-tab', this)">Users ($($users.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'groups-tab', this)">Groups ($($groups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'sps-tab', this)">Service Principals ($($sps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'devices-tab', this)">Devices ($($devices.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('principals-section', 'au-tab', this)">Admin Units ($($adminUnits.Count))</button>
                <span class="export-btns">
                    <button class="export-btn" onclick="event.stopPropagation(); exportToCSV(document.querySelector('#principals-section .tab-content.active table').id, 'principals')" title="Export to CSV">CSV</button>
                    <button class="export-btn" onclick="event.stopPropagation(); exportToJSON(document.querySelector('#principals-section .tab-content.active table').id, 'principals')" title="Export to JSON">JSON</button>
                </span>
            </div>
            <div id="users-tab" class="tab-content active">$(Build-Table $users 'users-tbl' $userCols 'users' $allPrincipals.Count)</div>
            <div id="groups-tab" class="tab-content">$(Build-Table $groups 'groups-tbl' $groupCols 'groups' $allPrincipals.Count)</div>
            <div id="sps-tab" class="tab-content">$(Build-Table $sps 'sps-tbl' $spCols 'service principals' $allPrincipals.Count)</div>
            <div id="devices-tab" class="tab-content">$(Build-Table $devices 'devices-tbl' $deviceCols 'devices' $allPrincipals.Count)</div>
            <div id="au-tab" class="tab-content">$(Build-Table $adminUnits 'au-tbl' $adminUnitCols 'administrative units' $allPrincipals.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 2: RESOURCES -->
    <div class="container" id="resources-section">
        <div class="container-header" onclick="toggleContainer('resources-section')">
            <span class="chevron">&#9660;</span>
            RESOURCES <span class="count">$($allResources.Count)</span>
            <span class="desc">applications + Azure resources</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('resources-section', 'apps-tab', this)">Applications ($($apps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'tenants-tab', this)">Tenants ($($tenants.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'mgmt-tab', this)">Mgmt Groups ($($mgmtGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'subs-tab', this)">Subscriptions ($($subscriptions.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'rgs-tab', this)">Resource Groups ($($resourceGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'kvs-tab', this)">Key Vaults ($($keyVaults.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'vms-tab', this)">VMs ($($vms.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'storage-tab', this)">Storage ($($storageAccounts.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'aks-tab', this)">AKS ($($aksClusters.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'acr-tab', this)">ACR ($($containerRegistries.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'vmss-tab', this)">VMSS ($($vmScaleSets.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'funcs-tab', this)">Functions ($($functionApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'logic-tab', this)">Logic Apps ($($logicApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'web-tab', this)">Web Apps ($($webApps.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'auto-tab', this)">Automation ($($automationAccounts.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('resources-section', 'adf-tab', this)">Data Factory ($($dataFactories.Count))</button>
                <span class="export-btns">
                    <button class="export-btn" onclick="event.stopPropagation(); exportToCSV(document.querySelector('#resources-section .tab-content.active table').id, 'resources')" title="Export to CSV">CSV</button>
                    <button class="export-btn" onclick="event.stopPropagation(); exportToJSON(document.querySelector('#resources-section .tab-content.active table').id, 'resources')" title="Export to JSON">JSON</button>
                </span>
            </div>
            <div id="apps-tab" class="tab-content active">$(Build-Table $apps 'apps-tbl' $appCols 'applications' $allResources.Count)</div>
            <div id="tenants-tab" class="tab-content">$(Build-Table $tenants 'tenants-tbl' $azureResCols 'tenants' $allResources.Count)</div>
            <div id="mgmt-tab" class="tab-content">$(Build-Table $mgmtGroups 'mgmt-tbl' $azureResCols 'management groups' $allResources.Count)</div>
            <div id="subs-tab" class="tab-content">$(Build-Table $subscriptions 'subs-tbl' $subsCols 'subscriptions' $allResources.Count)</div>
            <div id="rgs-tab" class="tab-content">$(Build-Table $resourceGroups 'rgs-tbl' $azureResCols 'resource groups' $allResources.Count)</div>
            <div id="kvs-tab" class="tab-content">$(Build-Table $keyVaults 'kvs-tbl' $azureResCols 'key vaults' $allResources.Count)</div>
            <div id="vms-tab" class="tab-content">$(Build-Table $vms 'vms-tbl' $azureResCols 'virtual machines' $allResources.Count)</div>
            <div id="storage-tab" class="tab-content">$(Build-Table $storageAccounts 'storage-tbl' $azureResCols 'storage accounts' $allResources.Count)</div>
            <div id="aks-tab" class="tab-content">$(Build-Table $aksClusters 'aks-tbl' $azureResCols 'AKS clusters' $allResources.Count)</div>
            <div id="acr-tab" class="tab-content">$(Build-Table $containerRegistries 'acr-tbl' $azureResCols 'container registries' $allResources.Count)</div>
            <div id="vmss-tab" class="tab-content">$(Build-Table $vmScaleSets 'vmss-tbl' $azureResCols 'VM scale sets' $allResources.Count)</div>
            <div id="funcs-tab" class="tab-content">$(Build-Table $functionApps 'funcs-tbl' $azureResCols 'function apps' $allResources.Count)</div>
            <div id="logic-tab" class="tab-content">$(Build-Table $logicApps 'logic-tbl' $azureResCols 'logic apps' $allResources.Count)</div>
            <div id="web-tab" class="tab-content">$(Build-Table $webApps 'web-tbl' $azureResCols 'web apps' $allResources.Count)</div>
            <div id="auto-tab" class="tab-content">$(Build-Table $automationAccounts 'auto-tbl' $azureResCols 'automation accounts' $allResources.Count)</div>
            <div id="adf-tab" class="tab-content">$(Build-Table $dataFactories 'adf-tbl' $azureResCols 'data factories' $allResources.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 3: EDGES -->
    <div class="container" id="edges-section">
        <div class="container-header" onclick="toggleContainer('edges-section')">
            <span class="chevron">&#9660;</span>
            EDGES <span class="count">$($allEdges.Count)</span>
            <span class="desc">relationships + paths</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('edges-section', 'gm-tab', this)">Group Members ($($groupMembers.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'dr-tab', this)">Directory Roles ($($directoryRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'pimr-tab', this)">PIM Roles ($($pimRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'pimg-tab', this)">PIM Groups ($($pimGroups.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'rbac-tab', this)">Azure RBAC ($($azureRbac.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ar-tab', this)">App Roles ($($appRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'own-tab', this)">Owners ($($owners.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'lic-tab', this)">Licenses ($($licenses.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'cnt-tab', this)">Contains ($($contains.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'kva-tab', this)">KV Access ($($kvAccess.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'mi-tab', this)">Managed Identity ($($managedIdentities.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'aum-tab', this)">AU Members ($($auMembers.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ausr-tab', this)">AU Scoped Roles ($($auScopedRoles.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'pimreq-tab', this)">PIM Requests ($($pimRequests.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'oauth2-tab', this)">OAuth2 Grants ($($oauth2Grants.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'rpa-tab', this)">Role Policy ($($rolePolicyAssignments.Count))</button>
                <button class="tab derived" onclick="event.stopPropagation(); showTab('edges-section', 'derived-tab', this)">Derived ($($derivedEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'ca-edge-tab', this)">CA Policy ($($caPolicyEdges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('edges-section', 'virtual-tab', this)">Intune Policy ($($virtualEdges.Count))</button>
                <span class="export-btns">
                    <button class="export-btn" onclick="event.stopPropagation(); exportToCSV(document.querySelector('#edges-section .tab-content.active table').id, 'edges')" title="Export to CSV">CSV</button>
                    <button class="export-btn" onclick="event.stopPropagation(); exportToJSON(document.querySelector('#edges-section .tab-content.active table').id, 'edges')" title="Export to JSON">JSON</button>
                </span>
            </div>
            <div id="gm-tab" class="tab-content active">$(Build-Table $groupMembers 'gm-tbl' $edgeCols 'group memberships' $allEdges.Count)</div>
            <div id="dr-tab" class="tab-content">$(Build-Table $directoryRoles 'dr-tbl' $edgeCols 'directory role assignments' $allEdges.Count)</div>
            <div id="pimr-tab" class="tab-content">$(Build-Table $pimRoles 'pimr-tbl' $edgeCols 'PIM role assignments' $allEdges.Count)</div>
            <div id="pimg-tab" class="tab-content">$(Build-Table $pimGroups 'pimg-tbl' $edgeCols 'PIM group assignments' $allEdges.Count)</div>
            <div id="rbac-tab" class="tab-content">$(Build-Table $azureRbac 'rbac-tbl' $azureRbacCols 'Azure RBAC assignments' $allEdges.Count)</div>
            <div id="ar-tab" class="tab-content">$(Build-Table $appRoles 'ar-tbl' $edgeCols 'app role assignments' $allEdges.Count)</div>
            <div id="own-tab" class="tab-content">$(Build-Table $owners 'own-tbl' $edgeCols 'ownership edges' $allEdges.Count)</div>
            <div id="lic-tab" class="tab-content">$(Build-Table $licenses 'lic-tbl' $edgeCols 'license assignments' $allEdges.Count)</div>
            <div id="cnt-tab" class="tab-content">$(Build-Table $contains 'cnt-tbl' $edgeCols 'containment edges' $allEdges.Count)</div>
            <div id="kva-tab" class="tab-content">$(Build-Table $kvAccess 'kva-tbl' $edgeCols 'Key Vault access' $allEdges.Count)</div>
            <div id="mi-tab" class="tab-content">$(Build-Table $managedIdentities 'mi-tbl' $edgeCols 'managed identity edges' $allEdges.Count)</div>
            <div id="aum-tab" class="tab-content">$(Build-Table $auMembers 'aum-tbl' $edgeCols 'AU membership edges' $allEdges.Count)</div>
            <div id="ausr-tab" class="tab-content">$(Build-Table $auScopedRoles 'ausr-tbl' $edgeCols 'AU scoped role edges' $allEdges.Count)</div>
            <div id="pimreq-tab" class="tab-content">$(Build-Table $pimRequests 'pimreq-tbl' $edgeCols 'PIM request edges' $allEdges.Count)</div>
            <div id="oauth2-tab" class="tab-content">$(Build-Table $oauth2Grants 'oauth2-tbl' $edgeCols 'OAuth2 permission grants' $allEdges.Count)</div>
            <div id="rpa-tab" class="tab-content">$(Build-Table $rolePolicyAssignments 'rpa-tbl' $edgeCols 'role policy assignments' $allEdges.Count)</div>
            <div id="derived-tab" class="tab-content">$(Build-Table $derivedEdges 'derived-tbl' $derivedEdgeCols 'derived abuse edges' $allEdges.Count)</div>
            <div id="ca-edge-tab" class="tab-content">$(Build-Table $caPolicyEdges 'ca-edge-tbl' $edgeCols 'CA policy edges' $allEdges.Count)</div>
            <div id="virtual-tab" class="tab-content">$(Build-Table $virtualEdges 'virtual-tbl' $edgeCols 'Intune policy edges' $allEdges.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 4: POLICIES -->
    <div class="container" id="policies-section">
        <div class="container-header" onclick="toggleContainer('policies-section')">
            <span class="chevron">&#9660;</span>
            POLICIES <span class="count">$($allPolicies.Count)</span>
            <span class="desc">CA, Intune, security policies, named locations</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('policies-section', 'ca-tab', this)">Conditional Access ($($caPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'rp-tab', this)">Role Policies ($($rolePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'compliance-tab', this)">Compliance ($($compliancePolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'appprot-tab', this)">App Protection ($($appProtectionPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'namedloc-tab', this)">Named Locations ($($namedLocations.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'authmethods-tab', this)">Auth Methods ($($authMethodsPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'secdefaults-tab', this)">Security Defaults ($($securityDefaultsPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'authz-tab', this)">Authorization ($($authorizationPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'crosstenant-tab', this)">Cross-Tenant ($($crossTenantPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'permgrant-tab', this)">Permission Grant ($($permissionGrantPolicies.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('policies-section', 'adminconsent-tab', this)">Admin Consent ($($adminConsentPolicies.Count))</button>
                <span class="export-btns">
                    <button class="export-btn" onclick="event.stopPropagation(); exportToCSV(document.querySelector('#policies-section .tab-content.active table').id, 'policies')" title="Export to CSV">CSV</button>
                    <button class="export-btn" onclick="event.stopPropagation(); exportToJSON(document.querySelector('#policies-section .tab-content.active table').id, 'policies')" title="Export to JSON">JSON</button>
                </span>
            </div>
            <div id="ca-tab" class="tab-content active">$(Build-Table $caPolicies 'ca-tbl' $policyCols 'CA policies' $allPolicies.Count)</div>
            <div id="rp-tab" class="tab-content">$(Build-Table $rolePolicies 'rp-tbl' $policyCols 'role policies' $allPolicies.Count)</div>
            <div id="compliance-tab" class="tab-content">$(Build-Table $compliancePolicies 'compliance-tbl' $intunePolicyCols 'compliance policies' $allPolicies.Count)</div>
            <div id="appprot-tab" class="tab-content">$(Build-Table $appProtectionPolicies 'appprot-tbl' $intunePolicyCols 'app protection policies' $allPolicies.Count)</div>
            <div id="namedloc-tab" class="tab-content">$(Build-Table $namedLocations 'namedloc-tbl' $namedLocCols 'named locations' $allPolicies.Count)</div>
            <div id="authmethods-tab" class="tab-content">$(Build-Table $authMethodsPolicies 'authmethods-tbl' $authMethodsCols 'authentication methods policy' $allPolicies.Count)</div>
            <div id="secdefaults-tab" class="tab-content">$(Build-Table $securityDefaultsPolicies 'secdefaults-tbl' $securityDefaultsCols 'security defaults policy' $allPolicies.Count)</div>
            <div id="authz-tab" class="tab-content">$(Build-Table $authorizationPolicies 'authz-tbl' $authorizationCols 'authorization policy' $allPolicies.Count)</div>
            <div id="crosstenant-tab" class="tab-content">$(Build-Table $crossTenantPolicies 'crosstenant-tbl' $crossTenantCols 'cross-tenant access policy' $allPolicies.Count)</div>
            <div id="permgrant-tab" class="tab-content">$(Build-Table $permissionGrantPolicies 'permgrant-tbl' $permissionGrantCols 'permission grant policies' $allPolicies.Count)</div>
            <div id="adminconsent-tab" class="tab-content">$(Build-Table $adminConsentPolicies 'adminconsent-tbl' $adminConsentCols 'admin consent request policy' $allPolicies.Count)</div>
        </div>
    </div>

    <!-- CONTAINER 5: HISTORICAL CHANGES (Delta Tracking) -->
    <div class="container" id="audit-section">
        <div class="container-header" onclick="toggleContainer('audit-section')">
            <span class="chevron">&#9660;</span>
            HISTORICAL CHANGES <span class="count">$($changes.Count)</span>
            <span class="desc">delta tracking - new, modified, deleted entities</span>
        </div>
        <div class="container-body">
            <div class="tabs">
                <button class="tab active" onclick="event.stopPropagation(); showTab('audit-section', 'changes-tab', this)">All ($($changes.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('audit-section', 'principal-changes-tab', this)">Principals ($($principalChanges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('audit-section', 'policy-changes-tab', this)">Policies ($($policyChanges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('audit-section', 'resource-changes-tab', this)">Resources ($($resourceChanges.Count))</button>
                <button class="tab" onclick="event.stopPropagation(); showTab('audit-section', 'edge-changes-tab', this)">Edges ($($edgeChanges.Count))</button>
                <span class="export-btns">
                    <button class="export-btn" onclick="event.stopPropagation(); exportToCSV(document.querySelector('#audit-section .tab-content.active table').id, 'audit-changes')" title="Export to CSV">CSV</button>
                    <button class="export-btn" onclick="event.stopPropagation(); exportToJSON(document.querySelector('#audit-section .tab-content.active table').id, 'audit-changes')" title="Export to JSON">JSON</button>
                </span>
            </div>
            <div id="changes-tab" class="tab-content active">$(Build-Table $changes 'changes-tbl' $auditCols 'historical changes' $changes.Count)</div>
            <div id="principal-changes-tab" class="tab-content">$(Build-Table $principalChanges 'principal-changes-tbl' $auditCols 'principal changes' $changes.Count)</div>
            <div id="policy-changes-tab" class="tab-content">$(Build-Table $policyChanges 'policy-changes-tbl' $auditCols 'policy changes' $changes.Count)</div>
            <div id="resource-changes-tab" class="tab-content">$(Build-Table $resourceChanges 'resource-changes-tbl' $auditCols 'resource changes' $changes.Count)</div>
            <div id="edge-changes-tab" class="tab-content">$(Build-Table $edgeChanges 'edge-changes-tbl' $auditCols 'edge changes' $changes.Count)</div>
        </div>
    </div>

</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Body = $html
        Headers = @{ "content-type" = "text/html" }
    })
} catch {
    Write-Error "Dashboard error: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body = "Error: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    })
}
