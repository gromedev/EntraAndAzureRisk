<#
.SYNOPSIS
    Generates attack path snapshots from Gremlin graph queries
.DESCRIPTION
    V3.1 Architecture: Timer-triggered function that generates static graph visualizations
    - Runs hourly
    - Executes predefined Gremlin queries for attack path analysis
    - Converts query results to DOT format for graph visualization
    - Stores results in blob storage as JSON and DOT files
    - Supports pre-rendered attack path visualizations

    Snapshot Categories:
    - paths-to-global-admin: Attack paths leading to Global Administrator role
    - dangerous-service-principals: Service principals with privileged role assignments
    - external-user-exposure: Guest user access to privileged resources
    - mfa-coverage-gaps: Principals excluded from MFA policies
    - pim-activation-risks: Roles without MFA activation requirement
#>

param($Timer)

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
    'COSMOS_GREMLIN_ENDPOINT' = 'Gremlin endpoint for graph queries'
    'COSMOS_GREMLIN_DATABASE' = 'Gremlin database name'
    'COSMOS_GREMLIN_CONTAINER' = 'Gremlin graph container name'
    'COSMOS_GREMLIN_KEY' = 'Gremlin API key'
    'STORAGE_ACCOUNT_NAME' = 'Storage account for snapshots'
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

#region Helper Functions

function ConvertTo-DotFormat {
    <#
    .SYNOPSIS
        Converts Gremlin path results to DOT graph format
    .DESCRIPTION
        Takes Gremlin path query results and generates DOT format for Graphviz rendering
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotName,

        [Parameter(Mandatory)]
        [array]$Paths,

        [string]$Title = ""
    )

    $dot = New-Object System.Text.StringBuilder

    [void]$dot.AppendLine("digraph `"$SnapshotName`" {")
    [void]$dot.AppendLine("  rankdir=LR;")
    [void]$dot.AppendLine("  node [shape=box, style=filled];")

    if ($Title) {
        [void]$dot.AppendLine("  label=`"$Title`";")
        [void]$dot.AppendLine("  labelloc=`"t`";")
    }

    # Track unique nodes and edges to avoid duplicates
    $nodes = @{}
    $edges = @{}

    foreach ($path in $Paths) {
        if ($path.objects -and $path.objects.Count -gt 0) {
            for ($i = 0; $i -lt $path.objects.Count; $i++) {
                $obj = $path.objects[$i]

                # Add node
                $nodeId = $obj.id ?? $obj
                $label = $obj.label ?? $obj.displayName ?? $nodeId
                $nodeKey = $nodeId -replace '[^a-zA-Z0-9]', '_'

                if (-not $nodes.ContainsKey($nodeKey)) {
                    # Color based on label/type
                    $fillColor = switch ($label) {
                        'user' { '#E3F2FD' }          # Light blue
                        'group' { '#E8F5E9' }         # Light green
                        'servicePrincipal' { '#FFF3E0' }  # Light orange
                        'directoryRoleDefinition' { '#FFEBEE' }  # Light red
                        'application' { '#F3E5F5' }   # Light purple
                        default { '#FAFAFA' }         # Light gray
                    }

                    $displayLabel = if ($obj.displayName) { $obj.displayName } else { $label }
                    $displayLabel = $displayLabel -replace '"', '\"'

                    [void]$dot.AppendLine("  $nodeKey [label=`"$displayLabel`", fillcolor=`"$fillColor`"];")
                    $nodes[$nodeKey] = $true
                }

                # Add edge to next node in path
                if ($i -lt $path.objects.Count - 1) {
                    $nextObj = $path.objects[$i + 1]
                    $nextNodeId = $nextObj.id ?? $nextObj
                    $nextNodeKey = $nextNodeId -replace '[^a-zA-Z0-9]', '_'
                    $edgeKey = "${nodeKey}_${nextNodeKey}"

                    if (-not $edges.ContainsKey($edgeKey)) {
                        # Get edge label if available
                        $edgeLabel = ""
                        if ($path.labels -and $path.labels.Count -gt $i) {
                            $edgeLabel = $path.labels[$i]
                        }

                        if ($edgeLabel) {
                            [void]$dot.AppendLine("  $nodeKey -> $nextNodeKey [label=`"$edgeLabel`"];")
                        }
                        else {
                            [void]$dot.AppendLine("  $nodeKey -> $nextNodeKey;")
                        }
                        $edges[$edgeKey] = $true
                    }
                }
            }
        }
    }

    [void]$dot.AppendLine("}")

    return $dot.ToString()
}

function Get-SnapshotQueries {
    <#
    .SYNOPSIS
        Returns predefined Gremlin queries for attack path analysis
    #>

    # Global Administrator role template ID
    $globalAdminRoleId = "62e90394-69f5-4237-9190-012177145e10"

    return @{
        'paths-to-global-admin' = @{
            Title = "Attack Paths to Global Administrator"
            Description = "Paths from any principal to Global Administrator role"
            Query = "g.V().hasLabel('directoryRoleDefinition').has('roleTemplateId', '$globalAdminRoleId').repeat(__.in().simplePath()).emit().limit(50).path()"
            Priority = 1
        }
        'dangerous-service-principals' = @{
            Title = "Service Principals with Privileged Roles"
            Description = "Service principals that have been assigned privileged directory roles"
            Query = "g.V().hasLabel('servicePrincipal').where(out('hasRole').hasLabel('directoryRoleDefinition').has('isPrivileged', true)).limit(30).path()"
            Priority = 2
        }
        'external-user-exposure' = @{
            Title = "Guest User Access to Privileged Resources"
            Description = "Guest users with paths to privileged roles"
            Query = "g.V().hasLabel('user').has('userType', 'Guest').repeat(out().simplePath()).until(hasLabel('directoryRoleDefinition').has('isPrivileged', true)).limit(30).path()"
            Priority = 3
        }
        'mfa-coverage-gaps' = @{
            Title = "Principals Excluded from MFA Policies"
            Description = "Principals that are excluded from Conditional Access policies requiring MFA"
            Query = "g.V().hasLabel('user', 'group').where(inE('caPolicyExcludesPrincipal').has('requiresMfa', true)).limit(50)"
            Priority = 4
        }
        'pim-activation-risks' = @{
            Title = "Roles Without MFA Activation Requirement"
            Description = "Role management policies that don't require MFA for activation"
            Query = "g.E().hasLabel('rolePolicyAssignment').has('requiresMfaOnActivation', false).limit(50)"
            Priority = 5
        }
        'group-nested-paths' = @{
            Title = "Deep Group Nesting Paths"
            Description = "Groups with deep nesting that could lead to privilege escalation"
            Query = "g.V().hasLabel('group').repeat(out('memberOf').simplePath()).emit().times(4).path().limit(30)"
            Priority = 6
        }
        'app-to-privileged-role' = @{
            Title = "Applications with Privileged Access"
            Description = "Applications whose service principals have privileged role assignments"
            Query = "g.V().hasLabel('application').out('hasServicePrincipal').where(out('hasRole').hasLabel('directoryRoleDefinition').has('isPrivileged', true)).limit(30).path()"
            Priority = 7
        }
    }
}

#endregion

#region Function Logic
try {
    Write-Information "Starting graph snapshot generation" -InformationAction Continue
    $startTime = Get-Date
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")

    # Get tokens
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    # Configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }
    $snapshotFolder = "$timestamp/snapshots"

    # Get Gremlin connection
    $gremlinConnection = Get-GremlinConnection

    # Get snapshot queries
    $snapshotQueries = Get-SnapshotQueries

    # Initialize statistics
    $stats = @{
        SnapshotsGenerated = 0
        TotalPaths = 0
        Errors = 0
    }

    $snapshotResults = @{}

    # Execute each snapshot query
    foreach ($snapshotName in ($snapshotQueries.Keys | Sort-Object { $snapshotQueries[$_].Priority })) {
        $snapshot = $snapshotQueries[$snapshotName]

        Write-Information "Generating snapshot: $snapshotName" -InformationAction Continue

        try {
            # Execute Gremlin query
            $result = Submit-GremlinQuery -Query $snapshot.Query -Connection $gremlinConnection

            # Extract paths/results
            $paths = @()
            if ($result.Documents) {
                $paths = $result.Documents
            }
            elseif ($result._items) {
                $paths = $result._items
            }
            elseif ($result -is [array]) {
                $paths = $result
            }

            $pathCount = if ($paths) { $paths.Count } else { 0 }
            Write-Information "  Found $pathCount paths/results" -InformationAction Continue

            # Store results
            $snapshotResult = @{
                name = $snapshotName
                title = $snapshot.Title
                description = $snapshot.Description
                timestamp = $timestamp
                pathCount = $pathCount
                paths = $paths
            }

            $snapshotResults[$snapshotName] = $snapshotResult
            $stats.TotalPaths += $pathCount

            # Generate DOT file for visualization if we have path results
            if ($pathCount -gt 0 -and $paths[0].objects) {
                $dotContent = ConvertTo-DotFormat -SnapshotName $snapshotName `
                    -Paths $paths -Title $snapshot.Title

                # Upload DOT file
                $dotBlobName = "$snapshotFolder/$snapshotName.dot"
                $dotUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$dotBlobName"
                $headers = @{
                    'Authorization' = "Bearer $storageToken"
                    'x-ms-version' = '2021-08-06'
                    'x-ms-blob-type' = 'BlockBlob'
                    'Content-Type' = 'text/plain; charset=utf-8'
                }
                Invoke-RestMethod -Uri $dotUri -Method Put -Headers $headers -Body $dotContent | Out-Null
                Write-Information "  Uploaded: $dotBlobName" -InformationAction Continue
            }

            # Upload JSON results
            $jsonBlobName = "$snapshotFolder/$snapshotName.json"
            $jsonContent = $snapshotResult | ConvertTo-Json -Depth 10 -Compress
            $jsonUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$jsonBlobName"
            $headers = @{
                'Authorization' = "Bearer $storageToken"
                'x-ms-version' = '2021-08-06'
                'x-ms-blob-type' = 'BlockBlob'
                'Content-Type' = 'application/json; charset=utf-8'
            }
            Invoke-RestMethod -Uri $jsonUri -Method Put -Headers $headers -Body $jsonContent | Out-Null
            Write-Information "  Uploaded: $jsonBlobName" -InformationAction Continue

            $stats.SnapshotsGenerated++
        }
        catch {
            Write-Warning "Failed to generate snapshot '$snapshotName': $_"
            $stats.Errors++

            $snapshotResults[$snapshotName] = @{
                name = $snapshotName
                title = $snapshot.Title
                error = $_.Exception.Message
                timestamp = $timestamp
            }
        }
    }

    # Generate summary manifest
    $manifest = @{
        generatedAt = $timestamp
        snapshotCount = $stats.SnapshotsGenerated
        totalPaths = $stats.TotalPaths
        errors = $stats.Errors
        snapshots = $snapshotResults.Values | ForEach-Object {
            @{
                name = $_.name
                title = $_.title
                pathCount = $_.pathCount
                hasError = [bool]$_.error
            }
        }
    }

    $manifestBlobName = "$snapshotFolder/manifest.json"
    $manifestJson = $manifest | ConvertTo-Json -Depth 5 -Compress
    $manifestUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$manifestBlobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type' = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod -Uri $manifestUri -Method Put -Headers $headers -Body $manifestJson | Out-Null
    Write-Information "Uploaded manifest: $manifestBlobName" -InformationAction Continue

    # Calculate duration
    $duration = ((Get-Date) - $startTime).TotalSeconds

    Write-Information "Graph snapshot generation complete in $([Math]::Round($duration, 2))s" -InformationAction Continue
    Write-Information "  Snapshots: $($stats.SnapshotsGenerated)" -InformationAction Continue
    Write-Information "  Total paths: $($stats.TotalPaths)" -InformationAction Continue
    Write-Information "  Errors: $($stats.Errors)" -InformationAction Continue

    return @{
        Success = $true
        DurationSeconds = $duration
        Timestamp = $timestamp
        SnapshotFolder = $snapshotFolder
        Statistics = $stats
    }
}
catch {
    Write-Error "Graph snapshot generation failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
#endregion
