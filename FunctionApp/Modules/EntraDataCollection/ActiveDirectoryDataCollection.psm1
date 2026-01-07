#Requires -Version 7.0
<#
    .NOTES

    Need
    - config.json $config

    $ThresholdGB
    $WarningGB
    $Buffer
    $FilePath

    - what about JSONL? First on disk and then streamed to blob?


.SYNOPSIS
    Active Directory specific functions
#>

#region LDAP Connection Management
function New-LDAPConnection {
    param (
        [Parameter(Mandatory)]
        [object]$Config,
        
        [int]$RetryCount = 0
    )
    
    $maxRetries = $Config.RetryAttempts
    
    while ($RetryCount -lt $maxRetries) {
        try {
            Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
            
            $domain = ($env:USERDNSDOMAIN -split '\.')[0]
            $identifier = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($domain, 389)
            $connection = New-Object System.DirectoryServices.Protocols.LdapConnection($identifier)
            $connection.SessionOptions.ProtocolVersion = 3
            $connection.SessionOptions.ReferralChasing = 'None'
            $connection.Timeout = New-TimeSpan -Seconds $Config.SearchTimeoutSeconds
            
            return $connection
        }
        catch {
            $RetryCount++
            if ($RetryCount -lt $maxRetries) {
                Write-Warning "LDAP connection failed, attempt $RetryCount of $maxRetries. Retrying in $($Config.RetryDelaySeconds) seconds..."
                Start-Sleep -Seconds $Config.RetryDelaySeconds
            }
            else {
                throw "Failed to establish LDAP connection after $maxRetries attempts: $_"
            }
        }
    }
}
function New-LDAPSearchRequest {
    param (
        [string]$SearchBase,
        [string]$Filter,
        [string[]]$Attributes
    )
    
    $searchRequest = New-Object System.DirectoryServices.Protocols.SearchRequest
    $searchRequest.DistinguishedName = $SearchBase
    $searchRequest.Filter = $Filter
    $searchRequest.Scope = [System.DirectoryServices.Protocols.SearchScope]::Subtree
    
    if ($Attributes) {
        $searchRequest.Attributes.AddRange($Attributes)
    }
    
    return $searchRequest
}
function Convert-LDAPDateTimeString {
    param (
        [object]$DateTimeValue
    )
    
    try {
        $dateString = if ($DateTimeValue -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($DateTimeValue)
        }
        else {
            $DateTimeValue.ToString()
        }
        
        if ($dateString -match '(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
            $date = [DateTime]::ParseExact(
                $matches[1..6] -join '',
                'yyyyMMddHHmmss',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            return $date.ToString("yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        
        return [DateTime]::Parse($dateString).ToString("yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return "NULL"
    }
}
#endregion
#region Memory Management
function Test-MemoryPressure {
    param (
        [double]$ThresholdGB,
        [double]$WarningGB
    )
    
    $currentMemory = (Get-Process -Id $pid).WorkingSet64 / 1GB
    
    if ($currentMemory -gt $ThresholdGB) {
        Write-Warning "Memory usage critical: $([Math]::Round($currentMemory, 2))GB"
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        Start-Sleep -Seconds 2
        return $true
    }
    elseif ($currentMemory -gt $WarningGB) {
        Write-Warning "Memory usage high: $([Math]::Round($currentMemory, 2))GB"
    }
    
    return $false
}
function Write-BufferToFile {
    param (
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Buffer,
        
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    if ($Buffer.Count -gt 0) {
        $Buffer | Add-Content -Path $FilePath -Encoding UTF8
        $Buffer.Clear()
    }
}
#endregion
#region Progress Management
function Save-Progress {
    param (
        [Parameter(Mandatory)]
        [hashtable]$Progress,
        
        [Parameter(Mandatory)]
        [string]$ProgressFile
    )
    
    $Progress | ConvertTo-Json -Depth 10 | Set-Content -Path $ProgressFile
}
function Get-Progress {
    param (
        [Parameter(Mandatory)]
        [string]$ProgressFile
    )
    
    if (Test-Path $ProgressFile) {
        Write-Verbose "Resuming from previous progress..."
        return Get-Content $ProgressFile | ConvertFrom-Json -AsHashtable
    }
    
    return $null
}
#endregion
#region AD Helper Functions
function Get-ADGroupFilter {
    param (
        [Parameter(Mandatory)]
        [object]$Config
    )
    if ($Config.ScopeToGroup -and $Config.TargetGroup) {
        Write-Verbose "Scoping AD collection to group: $($Config.TargetGroup)"
        # Get group DN
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $searchBase = $domain.GetDirectoryEntry().distinguishedName
        $groupSearcher = [System.DirectoryServices.DirectorySearcher]::new([ADSI]"LDAP://$searchBase")
        $groupSearcher.Filter = "(&(objectClass=group)(name=$($Config.TargetGroup)))"
        $groupSearcher.PropertiesToLoad.Add("distinguishedName") | Out-Null
        $groupResult = $groupSearcher.FindOne()
        if (-not $groupResult) {
            throw "Group '$($Config.TargetGroup)' not found in Active Directory"
        }
        $groupDN = $groupResult.Properties["distinguishedName"][0]
        Write-Verbose "Found group DN: $groupDN"
        # Return filter for users who are members of this group
        return "(&(objectCategory=user)(memberOf=$groupDN))"
    }
    else {
        Write-Verbose "Collecting all users in Active Directory"
        return "(objectCategory=user)"
    }
} 
function Get-ADGroupMemberCount {
    param (
        [Parameter(Mandatory)]
        [object]$Config
    )
    if ($Config.ScopeToGroup -and $Config.TargetGroup) {
        try {
            $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $searchBase = $domain.GetDirectoryEntry().distinguishedName
            $groupSearcher = [System.DirectoryServices.DirectorySearcher]::new([ADSI]"LDAP://$searchBase")
            $groupSearcher.Filter = "(&(objectClass=group)(name=$($Config.TargetGroup)))"
            $groupSearcher.PropertiesToLoad.Add("member") | Out-Null
            $groupResult = $groupSearcher.FindOne()
            if ($groupResult -and $groupResult.Properties["member"]) {
                return $groupResult.Properties["member"].Count
            }
            return 0
        }
        catch {
            Write-Warning "Could not get group member count: $_"
            return "Unknown"
        }
    }
    else {
        return "All AD Users"
    }
}
function Get-ADGroupType {
    param (
        [int]$GroupType
    )
    
    $types = @()
    
    # Handle negative values (security groups have 0x80000000 bit set, making them negative)
    $unsignedGroupType = if ($GroupType -lt 0) {
        [uint32]($GroupType + 4294967296)  # Convert to unsigned
    }
    else {
        [uint32]$GroupType
    }
    
    # Scope - check the bottom 4 bits
    $scopeBits = $unsignedGroupType -band 0x0000000F
    switch ($scopeBits) {
        2 { $types += "Global" }
        4 { $types += "DomainLocal" }  
        8 { $types += "Universal" }
        default {
            # Handle common edge cases
            if ($scopeBits -eq 0) {
                $types += "Global"  # Default for many groups
            }
            else {
                $types += "Unknown-Scope-$scopeBits"
            }
        }
    }
    
    # Type - check security bit (0x80000000)
    if ($unsignedGroupType -band 0x80000000) {
        $types += "Security"
    }
    else {
        $types += "Distribution"
    }
    
    return $types -join ' | '
}
#endregion
Export-ModuleMember -Function @(
    'New-LDAPConnection',
    'New-LDAPSearchRequest',
    'Test-MemoryPressure',
    'Write-BufferToFile',
    'Save-Progress',
    'Get-Progress'
    'Convert-LDAPDateTimeString',
    'Get-ADGroupType',
    'Get-ADGroupFilter',
    'Get-ADGroupMemberCount'
)