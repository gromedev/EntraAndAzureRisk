#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Entra ID specific functions with retry logic

    Removed
        Get-SKUMapping
        Get-GroupMemberCount
        Get-SecurityGroupMembers
#>

# Import common functions
Import-Module (Join-Path $PSScriptRoot "Common.Functions.psm1") -Force

#region Connection Management
function Connect-ToGraph {
    param (
        [Parameter(Mandatory)]
        [object]$Config,
        
        [int]$RetryCount = 0
    )
    
    $maxRetries = $Config.RetryAttempts
    
    while ($RetryCount -lt $maxRetries) {
        try {
            Connect-MgGraph -ClientId $Config.ClientId `
                           -TenantId $Config.TenantId `
                           -CertificateThumbprint $Config.CertificateThumbprint `
                           -NoWelcome
            
            $context = Get-MgContext
            if ($context) {
                Write-Host "Successfully connected to Graph API"
                return $true
            }
        }
        catch {
            $RetryCount++
            if ($RetryCount -lt $maxRetries) {
                Write-Warning "Graph connection failed, attempt $RetryCount of $maxRetries. Retrying in $($Config.RetryDelaySeconds) seconds..."
                Start-Sleep -Seconds $Config.RetryDelaySeconds
            }
            else {
                throw "Failed to connect to Graph API after $maxRetries attempts: $_"
            }
        }
    }
    
    return $false
}
#endregion

#region API Request Management
function Invoke-GraphWithRetry {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [Parameter(Mandatory)]
        [object]$Config,
        
        [string]$Method = "GET",
        
        [int]$RetryCount = 0
    )
    
    $maxRetries = $Config.RetryAttempts
    
    while ($RetryCount -lt $maxRetries) {
        try {
            # Add rate limit delay
            #if ($Config.RateLimitDelayMs -gt 0) {
            #    Start-Sleep -Milliseconds $Config.RateLimitDelayMs
            #Write-Host "ok"
            
            $result = Invoke-MgGraphRequest -Uri $Uri -Method $Method
            return $result
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            if ($statusCode -eq 429) {
                # Rate limited - check for Retry-After header
                $retryAfter = 60
                if ($_.Exception.Response.Headers.RetryAfter) {
                    $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                }
                Write-Warning "Rate limited. Waiting $retryAfter seconds..."
                Start-Sleep -Seconds $retryAfter
                # Don't count rate limit against retry count
                continue
            }
            
            $RetryCount++
            if ($RetryCount -lt $maxRetries) {
                Write-Warning "Graph request failed, attempt $RetryCount of $maxRetries. Retrying in $($Config.RetryDelaySeconds) seconds..."
                Start-Sleep -Seconds $Config.RetryDelaySeconds
            }
            else {
                throw "Graph request failed after $maxRetries attempts: $_"
            }
        }
    }
}
function Get-GraphBatch {
    param($NextLink, $Config)
    $response = Invoke-MgGraphRequest -Method GET -Uri $NextLink
    return @{
        Items = $response.value
        NextLink = $response.'@odata.nextLink'
    }
}
#endregion

#region Paging Functions
function Invoke-GraphRequestWithPaging {
    param (
        [string]$Uri,
        [object]$Config
    )
    $results = [System.Collections.ArrayList]::new()
    $currentUri = $Uri
    do {
        $response = Invoke-GraphWithRetry -Uri $currentUri -Config $Config
        if ($response.value) {
            [void]$results.AddRange($response.value)
        }
        $currentUri = $response.'@odata.nextLink'
    } while ($currentUri)
    return $results
}
#endregion

#region Group Filtering Functions
function Get-InitialUserQuery {
    param (
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$SelectFields,
        [Parameter(Mandatory)]
        [int]$BatchSize
    )
    if ($Config.ScopeToGroup -and $Config.TargetGroup) {
        Write-Host "Scoping collection to group: $($Config.TargetGroup)"
        # Get the group ID
        $groupResponse = Invoke-GraphWithRetry `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($Config.TargetGroup)'" `
            -Config $Config
        if (-not $groupResponse.value -or $groupResponse.value.Count -eq 0) {
            throw "Group '$($Config.TargetGroup)' not found in tenant"
        }
        $groupId = $groupResponse.value[0].id
        Write-Host "Found group ID: $groupId"
        return "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=$SelectFields&`$top=$BatchSize"
    }
    else {
        Write-Host "Collecting all users in tenant"
        return "https://graph.microsoft.com/v1.0/users?`$select=$SelectFields&`$top=$BatchSize"
    }
}
 
#endregion

Export-ModuleMember -Function @(
    'Connect-ToGraph',
    'Invoke-GraphWithRetry',
    'Get-GraphBatch',
    'Invoke-GraphRequestWithPaging',
    'Get-InitialUserQuery'
)