using namespace System.Net

# V3 Dashboard - Unified Container Architecture
# Uses 6 unified containers: principals, resources, edges, policies, events, audit
param(
    $Request,
    $TriggerMetadata,
    # Principals (filter by principalType: user, group, servicePrincipal, device, application)
    $principalsIn,
    # Resources (filter by resourceType: tenant, subscription, keyVault, virtualMachine, etc.)
    $resourcesIn,
    # Edges (filter by edgeType: groupMember, directoryRole, azureRbac, etc.)
    $edgesIn,
    # Policies (filter by policyType: conditionalAccess, roleManagement, etc.)
    $policiesIn,
    # Events (filter by eventType: signIn, audit)
    $eventsIn,
    # Audit trail (change tracking)
    $auditIn
)

Add-Type -AssemblyName System.Web
$modulePath = Join-Path $PSScriptRoot "..\Modules\EntraDataCollection\EntraDataCollection.psm1"
Import-Module $modulePath -Force

# Helper: Get dynamic properties with smart ordering and type-specific filtering
function Get-DynamicProperty {
    param($dataArray, [string]$dataType = "")

    if ($null -eq $dataArray -or $dataArray.Count -eq 0) { return @() }

    # Define allowed columns per entity type (only show relevant fields)
    $allowedColumns = @{
        "user" = @(
            'objectId', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType',
            'createdDateTime', 'lastSignInDateTime', 'passwordPolicies', 'usageLocation',
            'externalUserState', 'externalUserStateChangeDateTime',
            'onPremisesSyncEnabled', 'onPremisesSamAccountName', 'onPremisesUserPrincipalName',
            'onPremisesSecurityIdentifier', 'onPremisesExtensionAttributes',
            # Password and session timestamps (security analytics)
            'lastPasswordChangeDateTime', 'signInSessionsValidFromDateTime', 'refreshTokensValidFromDateTime',
            # Authentication methods (embedded)
            'perUserMfaState', 'hasAuthenticator', 'hasPhone', 'hasFido2', 'hasWindowsHello',
            'hasSoftwareOath', 'authMethodCount',
            # Phase 1b: Identity and contact fields
            'mail', 'mailNickname', 'proxyAddresses', 'employeeId', 'employeeHireDate', 'employeeType', 'companyName',
            'mobilePhone', 'businessPhones', 'department', 'jobTitle',
            'principalType', 'collectionTimestamp', 'deleted'
        )
        "group" = @(
            'objectId', 'displayName', 'description', 'securityEnabled', 'mailEnabled', 'mail',
            'groupTypes', 'membershipRule', 'isAssignableToRole', 'visibility', 'classification',
            'createdDateTime', 'deletedDateTime', 'onPremisesSyncEnabled', 'onPremisesSecurityIdentifier',
            # Member statistics
            'memberCountDirect', 'userMemberCount', 'groupMemberCount', 'servicePrincipalMemberCount', 'deviceMemberCount',
            # Phase 1b: Lifecycle and provisioning fields
            'expirationDateTime', 'renewedDateTime', 'resourceProvisioningOptions', 'resourceBehaviorOptions',
            'preferredDataLocation', 'onPremisesSamAccountName', 'onPremisesLastSyncDateTime',
            'principalType', 'collectionTimestamp', 'deleted'
        )
        "servicePrincipal" = @(
            'objectId', 'displayName', 'appId', 'appDisplayName', 'servicePrincipalType',
            'accountEnabled', 'appRoleAssignmentRequired', 'deletedDateTime', 'description', 'notes',
            'servicePrincipalNames', 'tags', 'addIns', 'oauth2PermissionScopes',
            'resourceSpecificApplicationPermissions',
            # Credentials (secrets and certificates)
            'keyCredentials', 'passwordCredentials', 'secretCount', 'certificateCount',
            # Phase 1b: Security and SSO fields
            'appOwnerOrganizationId', 'preferredSingleSignOnMode', 'signInAudience', 'verifiedPublisher',
            'homepage', 'loginUrl', 'logoutUrl', 'replyUrls',
            'principalType', 'collectionTimestamp', 'deleted'
        )
        "device" = @(
            'objectId', 'displayName', 'deviceId', 'accountEnabled', 'operatingSystem',
            'operatingSystemVersion', 'isCompliant', 'isManaged', 'trustType', 'profileType',
            'manufacturer', 'model', 'deviceVersion', 'approximateLastSignInDateTime',
            'createdDateTime', 'registrationDateTime',
            # Phase 1b: MDM and sync fields
            'extensionAttributes', 'onPremisesSyncEnabled', 'onPremisesLastSyncDateTime', 'mdmAppId', 'managementType', 'systemLabels',
            'principalType', 'collectionTimestamp', 'deleted'
        )
        "application" = @(
            'objectId', 'displayName', 'appId', 'createdDateTime', 'signInAudience', 'publisherDomain',
            'keyCredentials', 'passwordCredentials', 'secretCount', 'certificateCount',
            'requiredResourceAccess', 'apiPermissionCount', 'verifiedPublisher', 'isPublisherVerified',
            'federatedIdentityCredentials', 'hasFederatedCredentials', 'federatedCredentialCount',
            # Phase 1b: Platform config and claims
            'identifierUris', 'web', 'publicClient', 'spa', 'optionalClaims', 'groupMembershipClaims',
            'principalType', 'collectionTimestamp', 'deleted'
        )
        # Azure Resource types (Phase 2 + Phase 3)
        "azureResource" = @(
            'objectId', 'displayName', 'name', 'resourceType', 'location', 'subscriptionId', 'resourceGroupName',
            # Tenant fields
            'tenantType', 'defaultDomain', 'verifiedDomains',
            # Subscription fields
            'state', 'authorizationSource',
            # Key Vault fields
            'vaultUri', 'sku', 'enableRbacAuthorization', 'enableSoftDelete', 'enablePurgeProtection',
            'publicNetworkAccess', 'accessPolicyCount',
            # VM fields
            'vmId', 'vmSize', 'osType', 'powerState', 'identityType',
            'hasSystemAssignedIdentity', 'systemAssignedPrincipalId',
            'hasUserAssignedIdentity', 'userAssignedIdentityCount',
            # Automation Account fields (Phase 3)
            'creationTime', 'lastModifiedTime', 'disableLocalAuth',
            # Function App / Web App fields (Phase 3)
            'kind', 'httpsOnly', 'clientCertEnabled', 'defaultHostName', 'hostNames', 'serverFarmId',
            # Logic App fields (Phase 3)
            'accessEndpoint', 'triggerType', 'actionCount', 'createdTime', 'changedTime',
            'collectionTimestamp', 'deleted'
        )
        "azureRelationship" = @(
            'id', 'edgeType', 'sourceId', 'sourceType', 'sourceDisplayName',
            'targetId', 'targetType', 'targetDisplayName',
            # Contains fields
            'targetLocation', 'targetSubscriptionId',
            # Key Vault access fields
            'accessType', 'canGetSecrets', 'canListSecrets', 'canSetSecrets',
            'canGetKeys', 'canDecryptWithKey', 'canGetCertificates',
            # Managed identity fields
            'identityType', 'userAssignedIdentityId',
            'collectionTimestamp', 'deleted'
        )
    }

    # Priority ordering for each type
    $priority = switch ($dataType) {
        "user" { @('objectId', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'perUserMfaState', 'hasAuthenticator', 'authMethodCount') }
        "group" { @('objectId', 'displayName', 'securityEnabled', 'memberCountDirect', 'userMemberCount', 'groupMemberCount', 'groupTypes') }
        "servicePrincipal" { @('objectId', 'displayName', 'appId', 'servicePrincipalType', 'accountEnabled', 'secretCount', 'certificateCount') }
        "device" { @('objectId', 'displayName', 'deviceId', 'isCompliant', 'isManaged', 'operatingSystem') }
        "application" { @('objectId', 'displayName', 'appId', 'signInAudience', 'secretCount', 'certificateCount', 'apiPermissionCount', 'hasFederatedCredentials') }
        "relationship" { @('id', 'sourceDisplayName', 'edgeType', 'targetDisplayName', 'membershipType', 'inheritanceDepth', 'status') }
        "policy" { @('objectId', 'displayName', 'policyType', 'state') }
        "signIn" { @('id', 'userPrincipalName', 'errorCode', 'riskLevelAggregated', 'createdDateTime') }
        "audit" { @('id', 'activityDisplayName', 'category', 'result', 'activityDateTime') }
        "changes" { @('entityType', 'displayName', 'objectId', 'changeType', 'changeTimestamp') }
        "role" { @('objectId', 'displayName', 'roleType', 'isPrivileged', 'isBuiltIn') }
        "azureResource" { @('objectId', 'displayName', 'resourceType', 'location', 'subscriptionId', 'vaultUri', 'vmSize', 'powerState') }
        "azureRelationship" { @('id', 'sourceDisplayName', 'edgeType', 'targetDisplayName', 'identityType', 'canGetSecrets') }
        default { @('objectId', 'displayName') }
    }

    # Collect all unique property names (excluding Cosmos DB internals)
    $allProps = $dataArray | ForEach-Object {
        if ($_ -is [System.Collections.IDictionary]) { $_.Keys }
        else { $_.PSObject.Properties.Name }
    } | Where-Object { $_ -notmatch '^_' } | Select-Object -Unique | Sort-Object

    # Filter to only allowed columns if we have a whitelist for this type
    if ($allowedColumns.ContainsKey($dataType)) {
        $allProps = $allProps | Where-Object { $_ -in $allowedColumns[$dataType] }
    }

    return ($priority | Where-Object { $_ -in $allProps }) + ($allProps | Where-Object { $_ -notin $priority })
}

# Helper: Format value for display
function Format-DisplayValue {
    param($value, $propertyName)

    if ($null -eq $value) { return "<span class='no-data'>null</span>" }
    if ($value -is [bool]) { return $value.ToString() }

    # Handle arrays
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return "[]" }
        $firstItem = $value[0]
        if ($firstItem -is [System.Collections.IDictionary] -or $firstItem -is [PSCustomObject]) {
            $formattedItems = $value | ForEach-Object {
                $currentObj = $_
                $objProps = if ($currentObj -is [System.Collections.IDictionary]) { $currentObj.Keys } else { $currentObj.PSObject.Properties.Name }
                $propPairs = $objProps | ForEach-Object {
                    $propName = $_
                    $propValue = if ($currentObj -is [System.Collections.IDictionary]) { $currentObj[$propName] } else { $currentObj.$propName }
                    $propDisplay = if ($null -eq $propValue) { "null" } else { [System.Web.HttpUtility]::HtmlEncode($propValue.ToString()) }
                    "<b>$propName</b> $propDisplay"
                }
                "<div style='margin:4px 0;padding:4px;background:#f5f5f5;border-radius:3px;'>$($propPairs -join '; ')</div>"
            }
            return "<div style='font-size:0.85em;'>$($formattedItems -join '')</div>"
        } else {
            return "[" + ($value -join ", ") + "]"
        }
    }

    # Handle objects
    if ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject]) {
        $props = if ($value -is [System.Collections.IDictionary]) { $value.Keys } else { $value.PSObject.Properties.Name }
        $maxDisplay = 10
        $items = $props | Select-Object -First $maxDisplay | ForEach-Object {
            $pValue = if ($value -is [System.Collections.IDictionary]) { $value[$_] } else { $value.$_ }
            $displayValue = if ($null -eq $pValue) { "null" } else { [System.Web.HttpUtility]::HtmlEncode($pValue.ToString()) }
            "<div><b>$_ </b> $displayValue</div>"
        }
        if ($props.Count -gt $maxDisplay) { $items += "<div style='color:#666;font-style:italic;'>... +$($props.Count - $maxDisplay) more</div>" }
        return "<div style='font-size:0.85em;'>$($items -join '')</div>"
    }

    # Handle dates
    if ($propertyName -match 'DateTime|Timestamp') {
        try { return ([DateTime]::Parse($value)).ToString("yyyy-MM-dd HH:mm") }
        catch { Write-Verbose "Date parsing failed for: $value" }
    }

    # Color-code risk levels
    if ($propertyName -match 'riskLevel') {
        $color = switch ($value) {
            'high' { '#d13438' }
            'medium' { '#ff8c00' }
            'low' { '#107c10' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    # Color-code states
    if ($propertyName -eq 'state' -or $propertyName -eq 'status') {
        $color = switch -Regex ($value) {
            'enabled|active|success' { '#107c10' }
            'disabled|inactive|failed' { '#d13438' }
            'pending|reporting' { '#ff8c00' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    # Color-code change types
    if ($propertyName -eq 'changeType') {
        $color = switch ($value) {
            'new' { '#107c10' }
            'modified' { '#0078d4' }
            'deleted' { '#d13438' }
            default { '#666' }
        }
        return "<span style='color:$color;font-weight:bold;'>$value</span>"
    }

    return [System.Web.HttpUtility]::HtmlEncode($value)
}

# Helper: Format delta changes
function Format-Delta {
    param($delta)
    if ($null -eq $delta -or $delta.PSObject.Properties.Count -eq 0) { return "---" }
    ($delta.PSObject.Properties | ForEach-Object {
        $old = if ($null -eq $_.Value.old) { "null" } else { $_.Value.old }
        $new = if ($null -eq $_.Value.new) { "null" } else { $_.Value.new }
        "<div class='delta-item'><b>$($_.Name)</b>: <span class='delta-old'>$old</span> -> <span class='delta-new'>$new</span></div>"
    }) -join ''
}

# Helper: De-duplicate by objectId
function Remove-Duplicate {
    param($dataArray)
    if ($null -eq $dataArray -or $dataArray.Count -eq 0) { return @() }

    $unique = @{}
    foreach ($item in $dataArray) {
        $objectId = if ($item -is [System.Collections.IDictionary]) { $item['objectId'] } else { $item.objectId }
        if ($null -eq $objectId) { continue }

        $timestamp = if ($item -is [System.Collections.IDictionary]) {
            if ($item.ContainsKey('_ts')) { $item['_ts'] } else { $item['collectionTimestamp'] }
        } else {
            if ($item._ts) { $item._ts } else { $item.collectionTimestamp }
        }

        if (-not $unique.ContainsKey($objectId) -or $timestamp -gt $unique[$objectId].Timestamp) {
            $unique[$objectId] = @{ Item = $item; Timestamp = $timestamp }
        }
    }
    return $unique.Values | ForEach-Object { $_.Item }
}

# Helper: Build HTML table
function New-TableHtml {
    param($data, $tableId, $dataType = "")

    if ($data.Count -eq 0) { return @{ Headers = ""; Rows = ""; Props = @() } }

    $props = Get-DynamicProperty -dataArray $data -dataType $dataType

    $headers = (0..($props.Count - 1) | ForEach-Object {
        "<th onclick=`"sortTable($_, '$tableId')`">$($props[$_])</th>"
    }) -join ''

    $rows = ($data | ForEach-Object {
        $item = $_
        $cells = ($props | ForEach-Object {
            $value = if ($item -is [System.Collections.IDictionary]) { $item[$_] } else { $item.$_ }
            $displayValue = if ($_ -eq 'delta') { Format-Delta $value } else { Format-DisplayValue $value $_ }
            "<td>$displayValue</td>"
        }) -join ''
        "<tr>$cells</tr>"
    }) -join "`n"

    return @{ Headers = $headers; Rows = $rows; Props = $props }
}

try {
    # V3: Filter principals by principalType from unified container
    $allPrincipals = $principalsIn ?? @()
    $userData = Remove-Duplicate @($allPrincipals | Where-Object { $_.principalType -eq 'user' })
    $groupData = Remove-Duplicate @($allPrincipals | Where-Object { $_.principalType -eq 'group' })
    $spData = Remove-Duplicate @($allPrincipals | Where-Object { $_.principalType -eq 'servicePrincipal' })
    $deviceData = Remove-Duplicate @($allPrincipals | Where-Object { $_.principalType -eq 'device' })
    # V3: Applications are RESOURCES, not principals (semantic correctness)
    $appData = Remove-Duplicate @($allResources | Where-Object { $_.resourceType -eq 'application' })

    # V3: Filter edges by edgeType from unified container
    $allEdges = $edgesIn ?? @()
    $groupMembershipData = @($allEdges | Where-Object { $_.edgeType -eq 'groupMember' -or $_.edgeType -eq 'groupMemberTransitive' })
    $directoryRoleData = @($allEdges | Where-Object { $_.edgeType -eq 'directoryRole' })
    $pimRoleData = @($allEdges | Where-Object { $_.edgeType -match 'pimEligible|pimActive' })
    $pimGroupData = @($allEdges | Where-Object { $_.edgeType -match 'pimGroupEligible|pimGroupActive' })
    $azureRbacData = @($allEdges | Where-Object { $_.edgeType -eq 'azureRbac' })
    $appRoleData = @($allEdges | Where-Object { $_.edgeType -eq 'appRoleAssignment' })
    $ownershipData = @($allEdges | Where-Object { $_.edgeType -eq 'appOwner' -or $_.edgeType -eq 'spOwner' })
    $licenseData = @($allEdges | Where-Object { $_.edgeType -eq 'license' })

    # V3: Filter policies by policyType from unified container
    $allPolicies = $policiesIn ?? @()
    $caPolicyData = @($allPolicies | Where-Object { $_.policyType -eq 'conditionalAccess' })
    $rolePolicyData = @($allPolicies | Where-Object { $_.policyType -eq 'roleManagement' -or $_.policyType -eq 'roleManagementAssignment' })

    # V3: Filter events by eventType from unified container
    $allEvents = $eventsIn ?? @()
    $signInData = @($allEvents | Where-Object { $_.eventType -eq 'signIn' })
    $auditEventData = @($allEvents | Where-Object { $_.eventType -eq 'audit' })

    # V3: Process audit trail (change tracking from audit container)
    $changesData = $auditIn ?? @()

    # V3: Directory roles are now edges with edgeType='directoryRoleDefinition'
    $rolesData = @($allEdges | Where-Object { $_.edgeType -eq 'directoryRoleDefinition' })

    # V3: Filter resources by resourceType from unified container
    $allResources = $resourcesIn ?? @()
    $azureHierarchyData = @($allResources | Where-Object { $_.resourceType -in @('tenant', 'managementGroup', 'subscription', 'resourceGroup') })
    $keyVaultData = @($allResources | Where-Object { $_.resourceType -eq 'keyVault' })
    $virtualMachineData = @($allResources | Where-Object { $_.resourceType -eq 'virtualMachine' })
    # Phase 3 resource types
    $automationAccountData = @($allResources | Where-Object { $_.resourceType -eq 'automationAccount' })
    $functionAppData = @($allResources | Where-Object { $_.resourceType -eq 'functionApp' })
    $logicAppData = @($allResources | Where-Object { $_.resourceType -eq 'logicApp' })
    $webAppData = @($allResources | Where-Object { $_.resourceType -eq 'webApp' })

    # V3: Azure relationships are also edges - filter by edgeType
    $containsData = @($allEdges | Where-Object { $_.edgeType -eq 'contains' })
    $keyVaultAccessData = @($allEdges | Where-Object { $_.edgeType -eq 'keyVaultAccess' })
    $managedIdentityData = @($allEdges | Where-Object { $_.edgeType -eq 'hasManagedIdentity' })

    Write-Verbose "V3 Dashboard - Principals: Users=$($userData.Count), Groups=$($groupData.Count), SPs=$($spData.Count)"
    Write-Verbose "V3 Dashboard - Azure: Hierarchy=$($azureHierarchyData.Count), KeyVaults=$($keyVaultData.Count), VMs=$($virtualMachineData.Count)"
    Write-Verbose "V3 Dashboard - Phase 3: AutomationAccounts=$($automationAccountData.Count), FunctionApps=$($functionAppData.Count), LogicApps=$($logicAppData.Count), WebApps=$($webAppData.Count)"

    # Generate tables
    $userTable = New-TableHtml -data $userData -tableId 'u-table' -dataType 'user'
    $groupTable = New-TableHtml -data $groupData -tableId 'g-table' -dataType 'group'
    $spTable = New-TableHtml -data $spData -tableId 'sp-table' -dataType 'servicePrincipal'
    $deviceTable = New-TableHtml -data $deviceData -tableId 'd-table' -dataType 'device'
    $appTable = New-TableHtml -data $appData -tableId 'app-table' -dataType 'application'
    $groupMemberTable = New-TableHtml -data $groupMembershipData -tableId 'gm-table' -dataType 'relationship'
    $dirRoleTable = New-TableHtml -data $directoryRoleData -tableId 'dr-table' -dataType 'relationship'
    $pimRoleTable = New-TableHtml -data $pimRoleData -tableId 'pr-table' -dataType 'relationship'
    $pimGroupTable = New-TableHtml -data $pimGroupData -tableId 'pg-table' -dataType 'relationship'
    $rbacTable = New-TableHtml -data $azureRbacData -tableId 'rb-table' -dataType 'relationship'
    $appRoleTable = New-TableHtml -data $appRoleData -tableId 'ar-table' -dataType 'relationship'
    $ownershipTable = New-TableHtml -data $ownershipData -tableId 'ow-table' -dataType 'relationship'
    $licenseTable = New-TableHtml -data $licenseData -tableId 'lic-table' -dataType 'relationship'
    $caTable = New-TableHtml -data $caPolicyData -tableId 'ca-table' -dataType 'policy'
    $rolePolicyTable = New-TableHtml -data $rolePolicyData -tableId 'rp-table' -dataType 'policy'
    $signInTable = New-TableHtml -data $signInData -tableId 'si-table' -dataType 'signIn'
    $auditTable = New-TableHtml -data $auditEventData -tableId 'au-table' -dataType 'audit'
    $changesTable = New-TableHtml -data $changesData -tableId 'ch-table' -dataType 'changes'
    $rolesTable = New-TableHtml -data $rolesData -tableId 'ro-table' -dataType 'role'
    # Azure tables (Phase 2)
    $azureHierarchyTable = New-TableHtml -data $azureHierarchyData -tableId 'ah-table' -dataType 'azureResource'
    $keyVaultTable = New-TableHtml -data $keyVaultData -tableId 'kv-table' -dataType 'azureResource'
    $vmTable = New-TableHtml -data $virtualMachineData -tableId 'vm-table' -dataType 'azureResource'
    # Azure tables (Phase 3)
    $automationAccountTable = New-TableHtml -data $automationAccountData -tableId 'aa-table' -dataType 'azureResource'
    $functionAppTable = New-TableHtml -data $functionAppData -tableId 'fa-table' -dataType 'azureResource'
    $logicAppTable = New-TableHtml -data $logicAppData -tableId 'la-table' -dataType 'azureResource'
    $webAppTable = New-TableHtml -data $webAppData -tableId 'wa-table' -dataType 'azureResource'
    # Azure relationship tables
    $containsTable = New-TableHtml -data $containsData -tableId 'ct-table' -dataType 'azureRelationship'
    $kvAccessTable = New-TableHtml -data $keyVaultAccessData -tableId 'ka-table' -dataType 'azureRelationship'
    $miTable = New-TableHtml -data $managedIdentityData -tableId 'mi-table' -dataType 'azureRelationship'

    $debugInfo = @"
        <div style='background:#e8f4fd;padding:10px;margin:10px 0;border-left:4px solid #0078d4;border-radius:5px;font-size:0.85em;'>
            <b>V3 Unified Architecture - Data Summary:</b><br/>
            <b>Principals:</b> Users: <b>$($userData.Count)</b> | Groups: <b>$($groupData.Count)</b> | SPs: <b>$($spData.Count)</b> | Devices: <b>$($deviceData.Count)</b> | Apps: <b>$($appData.Count)</b><br/>
            <b>Relationships:</b> Group Members: <b>$($groupMembershipData.Count)</b> | Dir Roles: <b>$($directoryRoleData.Count)</b> | PIM Roles: <b>$($pimRoleData.Count)</b> | PIM Groups: <b>$($pimGroupData.Count)</b> | Azure RBAC: <b>$($azureRbacData.Count)</b> | Owners: <b>$($ownershipData.Count)</b> | Licenses: <b>$($licenseData.Count)</b><br/>
            <b>Policies:</b> CA: <b>$($caPolicyData.Count)</b> | Role Mgmt: <b>$($rolePolicyData.Count)</b><br/>
            <b>Events:</b> Sign-Ins: <b>$($signInData.Count)</b> | Audits: <b>$($auditEventData.Count)</b><br/>
            <b>Azure (Phase 2):</b> Hierarchy: <b>$($azureHierarchyData.Count)</b> | Key Vaults: <b>$($keyVaultData.Count)</b> | VMs: <b>$($virtualMachineData.Count)</b> | Contains: <b>$($containsData.Count)</b> | KV Access: <b>$($keyVaultAccessData.Count)</b> | Managed Identity: <b>$($managedIdentityData.Count)</b><br/>
            <b>Azure (Phase 3):</b> Automation: <b>$($automationAccountData.Count)</b> | Functions: <b>$($functionAppData.Count)</b> | Logic Apps: <b>$($logicAppData.Count)</b> | Web Apps: <b>$($webAppData.Count)</b><br/>
            <b>Changes:</b> <b>$($changesData.Count)</b> | <b>Roles:</b> <b>$($rolesData.Count)</b><br/>
            Generated: <b>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</b>
        </div>
"@

    $html = @"
<html>
<head>
    <title>Entra Risk Dashboard - V3</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; padding: 20px; background: #f4f4f9; margin: 0; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin-bottom: 20px; }
        .table-container { overflow-x: auto; max-width: 100%; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; background: white; white-space: nowrap; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; cursor: pointer; }
        th:hover { background: #005a9e; }
        td { padding: 10px; border-bottom: 1px solid #eee; font-size: 0.9em; }
        tr:hover { background: #f5f5f5; }
        .tabs { border-bottom: 2px solid #0078d4; margin-bottom: 15px; display: flex; flex-wrap: wrap; gap: 5px; }
        .tab { padding: 8px 15px; border: none; background: none; cursor: pointer; font-weight: bold; color: #666; font-size: 0.9em; }
        .tab.active { color: #0078d4; border-bottom: 3px solid #0078d4; }
        .tab:hover { color: #0078d4; }
        .tab-content { display: none; } .tab-content.active { display: block; }
        .delta-old { color: #d13438; text-decoration: line-through; } .delta-new { color: #107c10; }
        .delta-item { margin: 2px 0; padding: 3px; background: #f9f9f9; border-radius: 3px; }
        .no-data { color: #999; font-style: italic; }
        .tab-divider { border-left: 2px solid #ddd; margin: 0 10px; height: 30px; }
        .section-label { color: #666; font-size: 0.8em; margin-right: 5px; }
    </style>
    <script>
        function showTab(id, btn) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
            document.getElementById(id).classList.add('active'); btn.classList.add('active');
        }
        function sortTable(n, tableId) {
            var table = document.getElementById(tableId), rows, switching = true, dir = "asc", switchcount = 0;
            while (switching) {
                switching = false; rows = table.rows;
                for (var i = 1; i < rows.length - 1; i++) {
                    var x = rows[i].getElementsByTagName("TD")[n], y = rows[i + 1].getElementsByTagName("TD")[n];
                    if ((dir == "asc" && x.innerHTML.toLowerCase() > y.innerHTML.toLowerCase()) ||
                        (dir == "desc" && x.innerHTML.toLowerCase() < y.innerHTML.toLowerCase())) {
                        rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                        switching = true; switchcount++; break;
                    }
                }
                if (switchcount == 0 && dir == "asc") { dir = "desc"; switching = true; }
            }
        }
    </script>
</head>
<body>
    <h2>Entra Risk Dashboard - V3</h2>
    $debugInfo
    <div class="card">
        <div class="tabs">
            <span class="section-label">PRINCIPALS:</span>
            <button class="tab active" onclick="showTab('u-tab', this)">Users ($($userData.Count))</button>
            <button class="tab" onclick="showTab('g-tab', this)">Groups ($($groupData.Count))</button>
            <button class="tab" onclick="showTab('sp-tab', this)">SPs ($($spData.Count))</button>
            <button class="tab" onclick="showTab('d-tab', this)">Devices ($($deviceData.Count))</button>
            <button class="tab" onclick="showTab('app-tab', this)">Apps ($($appData.Count))</button>
            <span class="tab-divider"></span>
            <span class="section-label">RELATIONSHIPS:</span>
            <button class="tab" onclick="showTab('gm-tab', this)">Group Members ($($groupMembershipData.Count))</button>
            <button class="tab" onclick="showTab('dr-tab', this)">Dir Roles ($($directoryRoleData.Count))</button>
            <button class="tab" onclick="showTab('pr-tab', this)">PIM Roles ($($pimRoleData.Count))</button>
            <button class="tab" onclick="showTab('pg-tab', this)">PIM Groups ($($pimGroupData.Count))</button>
            <button class="tab" onclick="showTab('rb-tab', this)">Azure RBAC ($($azureRbacData.Count))</button>
            <button class="tab" onclick="showTab('ow-tab', this)">Owners ($($ownershipData.Count))</button>
            <button class="tab" onclick="showTab('lic-tab', this)">Licenses ($($licenseData.Count))</button>
            <button class="tab" onclick="showTab('ar-tab', this)">App Roles ($($appRoleData.Count))</button>
            <span class="tab-divider"></span>
            <span class="section-label">POLICIES:</span>
            <button class="tab" onclick="showTab('ca-tab', this)">CA Policies ($($caPolicyData.Count))</button>
            <button class="tab" onclick="showTab('rp-tab', this)">Role Policies ($($rolePolicyData.Count))</button>
            <span class="tab-divider"></span>
            <span class="section-label">EVENTS:</span>
            <button class="tab" onclick="showTab('si-tab', this)">Sign-Ins ($($signInData.Count))</button>
            <button class="tab" onclick="showTab('au-tab', this)">Audits ($($auditEventData.Count))</button>
            <button class="tab" onclick="showTab('ch-tab', this)">Changes ($($changesData.Count))</button>
            <span class="tab-divider"></span>
            <span class="section-label">REFERENCE:</span>
            <button class="tab" onclick="showTab('ro-tab', this)">Roles ($($rolesData.Count))</button>
            <span class="tab-divider"></span>
            <span class="section-label">AZURE:</span>
            <button class="tab" onclick="showTab('ah-tab', this)">Hierarchy ($($azureHierarchyData.Count))</button>
            <button class="tab" onclick="showTab('kv-tab', this)">Key Vaults ($($keyVaultData.Count))</button>
            <button class="tab" onclick="showTab('vm-tab', this)">VMs ($($virtualMachineData.Count))</button>
            <button class="tab" onclick="showTab('aa-tab', this)">Automation ($($automationAccountData.Count))</button>
            <button class="tab" onclick="showTab('fa-tab', this)">Functions ($($functionAppData.Count))</button>
            <button class="tab" onclick="showTab('la-tab', this)">Logic Apps ($($logicAppData.Count))</button>
            <button class="tab" onclick="showTab('wa-tab', this)">Web Apps ($($webAppData.Count))</button>
            <button class="tab" onclick="showTab('ct-tab', this)">Contains ($($containsData.Count))</button>
            <button class="tab" onclick="showTab('ka-tab', this)">KV Access ($($keyVaultAccessData.Count))</button>
            <button class="tab" onclick="showTab('mi-tab', this)">Managed Identity ($($managedIdentityData.Count))</button>
        </div>

        <!-- Principals -->
        <div id="u-tab" class="tab-content active">
            <div class="table-container"><table id="u-table"><thead><tr>$($userTable.Headers)</tr></thead><tbody>$($userTable.Rows)</tbody></table></div>
        </div>
        <div id="g-tab" class="tab-content">
            <div class="table-container"><table id="g-table"><thead><tr>$($groupTable.Headers)</tr></thead><tbody>$($groupTable.Rows)</tbody></table></div>
        </div>
        <div id="sp-tab" class="tab-content">
            <div class="table-container"><table id="sp-table"><thead><tr>$($spTable.Headers)</tr></thead><tbody>$($spTable.Rows)</tbody></table></div>
        </div>
        <div id="d-tab" class="tab-content">
            <div class="table-container"><table id="d-table"><thead><tr>$($deviceTable.Headers)</tr></thead><tbody>$($deviceTable.Rows)</tbody></table></div>
        </div>
        <div id="app-tab" class="tab-content">
            <div class="table-container"><table id="app-table"><thead><tr>$($appTable.Headers)</tr></thead><tbody>$($appTable.Rows)</tbody></table></div>
        </div>

        <!-- Relationships -->
        <div id="gm-tab" class="tab-content">
            <div class="table-container"><table id="gm-table"><thead><tr>$($groupMemberTable.Headers)</tr></thead><tbody>$($groupMemberTable.Rows)</tbody></table></div>
        </div>
        <div id="dr-tab" class="tab-content">
            <div class="table-container"><table id="dr-table"><thead><tr>$($dirRoleTable.Headers)</tr></thead><tbody>$($dirRoleTable.Rows)</tbody></table></div>
        </div>
        <div id="pr-tab" class="tab-content">
            <div class="table-container"><table id="pr-table"><thead><tr>$($pimRoleTable.Headers)</tr></thead><tbody>$($pimRoleTable.Rows)</tbody></table></div>
        </div>
        <div id="pg-tab" class="tab-content">
            <div class="table-container"><table id="pg-table"><thead><tr>$($pimGroupTable.Headers)</tr></thead><tbody>$($pimGroupTable.Rows)</tbody></table></div>
        </div>
        <div id="rb-tab" class="tab-content">
            <div class="table-container"><table id="rb-table"><thead><tr>$($rbacTable.Headers)</tr></thead><tbody>$($rbacTable.Rows)</tbody></table></div>
        </div>
        <div id="ow-tab" class="tab-content">
            <div class="table-container"><table id="ow-table"><thead><tr>$($ownershipTable.Headers)</tr></thead><tbody>$($ownershipTable.Rows)</tbody></table></div>
        </div>
        <div id="lic-tab" class="tab-content">
            <div class="table-container"><table id="lic-table"><thead><tr>$($licenseTable.Headers)</tr></thead><tbody>$($licenseTable.Rows)</tbody></table></div>
        </div>
        <div id="ar-tab" class="tab-content">
            <div class="table-container"><table id="ar-table"><thead><tr>$($appRoleTable.Headers)</tr></thead><tbody>$($appRoleTable.Rows)</tbody></table></div>
        </div>

        <!-- Policies -->
        <div id="ca-tab" class="tab-content">
            <div class="table-container"><table id="ca-table"><thead><tr>$($caTable.Headers)</tr></thead><tbody>$($caTable.Rows)</tbody></table></div>
        </div>
        <div id="rp-tab" class="tab-content">
            <div class="table-container"><table id="rp-table"><thead><tr>$($rolePolicyTable.Headers)</tr></thead><tbody>$($rolePolicyTable.Rows)</tbody></table></div>
        </div>

        <!-- Events -->
        <div id="si-tab" class="tab-content">
            <div class="table-container"><table id="si-table"><thead><tr>$($signInTable.Headers)</tr></thead><tbody>$($signInTable.Rows)</tbody></table></div>
        </div>
        <div id="au-tab" class="tab-content">
            <div class="table-container"><table id="au-table"><thead><tr>$($auditTable.Headers)</tr></thead><tbody>$($auditTable.Rows)</tbody></table></div>
        </div>
        <div id="ch-tab" class="tab-content">
            <div class="table-container"><table id="ch-table"><thead><tr>$($changesTable.Headers)</tr></thead><tbody>$($changesTable.Rows)</tbody></table></div>
        </div>

        <!-- Reference -->
        <div id="ro-tab" class="tab-content">
            <div class="table-container"><table id="ro-table"><thead><tr>$($rolesTable.Headers)</tr></thead><tbody>$($rolesTable.Rows)</tbody></table></div>
        </div>

        <!-- Azure Resources (Phase 2) -->
        <div id="ah-tab" class="tab-content">
            <div class="table-container"><table id="ah-table"><thead><tr>$($azureHierarchyTable.Headers)</tr></thead><tbody>$($azureHierarchyTable.Rows)</tbody></table></div>
        </div>
        <div id="kv-tab" class="tab-content">
            <div class="table-container"><table id="kv-table"><thead><tr>$($keyVaultTable.Headers)</tr></thead><tbody>$($keyVaultTable.Rows)</tbody></table></div>
        </div>
        <div id="vm-tab" class="tab-content">
            <div class="table-container"><table id="vm-table"><thead><tr>$($vmTable.Headers)</tr></thead><tbody>$($vmTable.Rows)</tbody></table></div>
        </div>
        <div id="aa-tab" class="tab-content">
            <div class="table-container"><table id="aa-table"><thead><tr>$($automationAccountTable.Headers)</tr></thead><tbody>$($automationAccountTable.Rows)</tbody></table></div>
        </div>
        <div id="fa-tab" class="tab-content">
            <div class="table-container"><table id="fa-table"><thead><tr>$($functionAppTable.Headers)</tr></thead><tbody>$($functionAppTable.Rows)</tbody></table></div>
        </div>
        <div id="la-tab" class="tab-content">
            <div class="table-container"><table id="la-table"><thead><tr>$($logicAppTable.Headers)</tr></thead><tbody>$($logicAppTable.Rows)</tbody></table></div>
        </div>
        <div id="wa-tab" class="tab-content">
            <div class="table-container"><table id="wa-table"><thead><tr>$($webAppTable.Headers)</tr></thead><tbody>$($webAppTable.Rows)</tbody></table></div>
        </div>
        <div id="ct-tab" class="tab-content">
            <div class="table-container"><table id="ct-table"><thead><tr>$($containsTable.Headers)</tr></thead><tbody>$($containsTable.Rows)</tbody></table></div>
        </div>
        <div id="ka-tab" class="tab-content">
            <div class="table-container"><table id="ka-table"><thead><tr>$($kvAccessTable.Headers)</tr></thead><tbody>$($kvAccessTable.Rows)</tbody></table></div>
        </div>
        <div id="mi-tab" class="tab-content">
            <div class="table-container"><table id="mi-table"><thead><tr>$($miTable.Headers)</tr></thead><tbody>$($miTable.Rows)</tbody></table></div>
        </div>
    </div>
</body>
</html>
"@

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $html; Headers = @{"content-type"="text/html"} })
} catch {
    Write-Error "Dashboard error: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "Error: $($_.Exception.Message)" })
}
