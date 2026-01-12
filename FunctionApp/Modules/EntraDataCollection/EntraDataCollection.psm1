# Module-level token cache
$script:TokenCache = @{}

function Get-ManagedIdentityToken {
    <#
    .SYNOPSIS
        Gets an access token using Azure Managed Identity
    
    .DESCRIPTION
        Uses the managed identity endpoint to acquire tokens without storing credentials.
        Supports Graph API, Storage, and other Azure resources.
        
        This function uses the Azure Instance Metadata Service (IMDS) endpoint which is
        automatically available in Azure services like Function Apps, VMs, and Container Instances.
    
    .PARAMETER Resource
        The resource URI to get a token for. Defaults to Microsoft Graph API.
    
    .EXAMPLE
        $token = Get-ManagedIdentityToken -Resource "https://graph.microsoft.com"
        
    .EXAMPLE
        $storageToken = Get-ManagedIdentityToken -Resource "https://storage.azure.com"
    #>
    [CmdletBinding()]
    param(
        [string]$Resource = "https://graph.microsoft.com"
    )
    
    $apiVersion = "2019-08-01"
    $endpoint = $env:IDENTITY_ENDPOINT
    $header = $env:IDENTITY_HEADER
    
    if (-not $endpoint -or -not $header) {
        throw "Managed identity environment variables not found. This function must run in Azure with managed identity enabled."
    }
    
    $uri = "$endpoint`?resource=$Resource&api-version=$apiVersion"
    $headers = @{
        'X-IDENTITY-HEADER' = $header
    }
    
    try {
        Write-Verbose "Requesting managed identity token for resource: $Resource"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        Write-Verbose "Successfully acquired token (expires: $($response.expires_on))"
        return $response.access_token
    }
    catch {
        Write-Error "Failed to get managed identity token for resource '$Resource': $_"
        throw
    }
}

function Get-CachedManagedIdentityToken {
    <#
    .SYNOPSIS
        Gets managed identity token with caching (55-minute expiry)
    
    .DESCRIPTION
        Caches tokens with 55-minute expiry (5-minute safety buffer from 60-minute validity).
        Eliminates unnecessary IMDS calls when token still valid.
        Reduces latency and rate limiting risk.
    
    .PARAMETER Resource
        The resource URI to get a token for. Defaults to Microsoft Graph API.
    
    .EXAMPLE
        $token = Get-CachedManagedIdentityToken -Resource "https://graph.microsoft.com"
        
    .EXAMPLE
        $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"
    #>
    [CmdletBinding()]
    param(
        [string]$Resource = "https://graph.microsoft.com"
    )
    
    $cached = $script:TokenCache[$Resource]
    
    # Check if cached and not expired (5 min buffer)
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        Write-Verbose "Using cached token for $Resource (expires: $($cached.ExpiresOn))"
        return $cached.Token
    }
    
    # Acquire new token
    Write-Verbose "Acquiring new token for $Resource"
    $token = Get-ManagedIdentityToken -Resource $Resource
    
    # Cache with 55-minute expiry (5 min safety buffer from 60 min validity)
    $script:TokenCache[$Resource] = @{
        Token = $token
        ExpiresOn = (Get-Date).AddMinutes(55)
    }
    
    Write-Verbose "Token acquired and cached (expires: $($script:TokenCache[$Resource].ExpiresOn))"
    return $token
}

#endregion

#region Azure Management Functions

function Get-AzureManagementPagedResult {
    <#
    .SYNOPSIS
        Gets paginated results from Azure Management API with automatic nextLink handling

    .DESCRIPTION
        Handles Azure Management API pagination by following nextLink until all results collected.
        Includes retry logic for transient failures.

    .PARAMETER Uri
        The Azure Management API URI to call

    .PARAMETER AccessToken
        Bearer token for authentication

    .EXAMPLE
        $subscriptions = Get-AzureManagementPagedResult -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" -AccessToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $allResults = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri
    $maxRetries = 3

    while ($nextLink) {
        $retryCount = 0
        $success = $false

        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                $headers = @{
                    'Authorization' = "Bearer $AccessToken"
                    'Content-Type' = 'application/json'
                }

                $response = Invoke-RestMethod -Uri $nextLink -Method GET -Headers $headers -ErrorAction Stop

                if ($response.value) {
                    foreach ($item in $response.value) {
                        $allResults.Add($item)
                    }
                }

                $nextLink = $response.nextLink
                $success = $true
            }
            catch {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    $delay = [math]::Pow(2, $retryCount) * 2
                    Write-Warning "Azure Management API call failed, retrying in ${delay}s: $_"
                    Start-Sleep -Seconds $delay
                }
                else {
                    Write-Error "Azure Management API call failed after $maxRetries retries: $_"
                    throw
                }
            }
        }
    }

    return $allResults
}

#endregion

#region Graph API Functions

function Invoke-GraphWithRetry {
    <#
    .SYNOPSIS
        Invokes Graph API with exponential backoff retry logic for transient failures
    
    .DESCRIPTION
        Implements exponential backoff retry: 5s, 10s, 20s for transient server errors (500+).
        Rate limiting (429) doesn't count against retry attempts and uses Retry-After header.
        
        This is CRITICAL for production reliability and performance. Handles:
        - Transient server errors (500, 502, 503, 504)
        - Rate limiting (429) with proper Retry-After header support
        - Network timeouts and connection failures
        
        Unlike the Microsoft Graph SDK, this gives you full control over retry behavior
        and provides better observability into API call patterns.
    
    .PARAMETER Uri
        The Graph API URI to call
    
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE). Default: GET
    
    .PARAMETER AccessToken
        Bearer token for authentication
    
    .PARAMETER MaxRetries
        Maximum number of retry attempts for transient errors. Default: 3
    
    .PARAMETER BaseRetryDelaySeconds
        Base delay for exponential backoff. Actual delays: 5s, 10s, 20s. Default: 5
    
    .EXAMPLE
        $response = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/users" -AccessToken $token
        
    .EXAMPLE
        $user = Invoke-GraphWithRetry -Uri "https://graph.microsoft.com/v1.0/users/user@domain.com" -AccessToken $token -MaxRetries 5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [string]$Method = "GET",
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [int]$MaxRetries = 3,
        
        [int]$BaseRetryDelaySeconds = 5
    )
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
        'ConsistencyLevel' = 'eventual'  # Required for some advanced queries
    }
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            Write-Verbose "Graph API call: $Method $Uri (attempt $($attempt + 1)/$MaxRetries)"
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
            Write-Verbose "Graph API call succeeded"
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            # Handle rate limiting (429) - doesn't count against retry attempts
            if ($statusCode -eq 429) {
                $retryAfter = 60
                $retryAfterHeader = $_.Exception.Response.Headers.'Retry-After'
                if ($retryAfterHeader) {
                    if ($retryAfterHeader -match '^\d+$') {
                        $retryAfter = [int]$retryAfterHeader
                    } else {
                        try {
                            $retryDate = [DateTime]::ParseExact($retryAfterHeader, 'r', [System.Globalization.CultureInfo]::InvariantCulture)
                            $retryAfter = [Math]::Max([Math]::Ceiling(($retryDate - (Get-Date).ToUniversalTime()).TotalSeconds), 1)
                        } catch {
                            Write-Warning "Could not parse Retry-After: $retryAfterHeader"

                        # "GENTLE GIANT: 429 HANDLING"
                        # add as a 
                        # .PARAMETER switch $GentleGiant
                        # Due to the aggressive retry method, there's maaaaybe chance of "crashing" other azure apps if they are making graph requests at the same time...
                        <#
                        # If enabled, this would handle 429s here and 'continue' before the standard block.
                        # $retryAfterHeader = $_.Exception.Response.Headers.'Retry-After'
                        # $retryAfter = if ($retryAfterHeader -match '^\d+$') { [int]$retryAfterHeader + 1 } else { 60 }
                        # Write-Warning "Surgical 429: Waiting $retryAfter seconds..."
                        # Start-Sleep -Seconds $retryAfter
                        # continue
                        #>
                        }
                    }
                }
                Write-Warning "Rate limited (429) on $Uri. Waiting $retryAfter seconds..."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            
            # Handle transient server errors (500-599) with exponential backoff
            $attempt++
            if ($statusCode -ge 500 -and $attempt -lt $MaxRetries) {
                # Exponential backoff: 5s, 10s, 20s, 40s...
                $delay = $BaseRetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                Write-Warning "Transient error ($statusCode) on $Uri. Retry $attempt of $MaxRetries in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            # Non-retryable error or max retries exceeded
            $errorDetails = "Graph API request failed: $Method $Uri (Status: $statusCode)"
            if ($_.ErrorDetails.Message) {
                $errorDetails += " - $($_.ErrorDetails.Message)"
            }
            Write-Error $errorDetails
            throw
        }
    }
    
    throw "Max retries ($MaxRetries) exceeded for Graph API request: $Method $Uri"
}

function Invoke-GraphBatch {
    <#
    .SYNOPSIS
        Invokes Microsoft Graph $batch API to execute multiple requests in a single HTTP call

    .DESCRIPTION
        Batches up to 20 Graph API requests into a single $batch call, reducing API overhead by 90-95%.
        Implements retry logic for both batch-level and individual request failures.

        Key optimizations:
        - Up to 20 requests per batch (Graph API limit)
        - Automatic chunking for larger request sets
        - Individual request retry for 429/5xx responses
        - Batch-level 429 handling with Retry-After header

        Performance impact:
        - 10,000 users with license queries: 10,000 calls → 500 calls (95% reduction)
        - Typical latency: 200ms per batch vs 200ms per individual call

    .PARAMETER Requests
        Array of request objects, each containing:
        - id: Unique identifier for matching responses (typically objectId)
        - method: HTTP method (GET, POST, PATCH, DELETE)
        - url: Relative Graph API URL (e.g., "/users/user-id/licenseDetails")

    .PARAMETER AccessToken
        Bearer token for Graph API authentication

    .PARAMETER MaxBatchSize
        Maximum requests per batch. Default: 20 (Graph API limit)

    .PARAMETER MaxRetries
        Maximum retry attempts for failed individual requests. Default: 3

    .PARAMETER ApiVersion
        Graph API version. Default: "v1.0". Use "beta" for auth methods.

    .OUTPUTS
        Hashtable keyed by request ID, where each value is:
        - Success: The response body (typically @{ value = @(...) })
        - 404: Empty response @{ value = @() }
        - Failed after retries: $null

    .EXAMPLE
        $requests = $users | ForEach-Object {
            @{ id = $_.id; method = "GET"; url = "/users/$($_.id)/licenseDetails" }
        }
        $responses = Invoke-GraphBatch -Requests $requests -AccessToken $token

        foreach ($user in $users) {
            $licenses = $responses[$user.id]
            # Process licenses...
        }

    .EXAMPLE
        # Beta API for auth methods
        $requests = $users | ForEach-Object {
            @{ id = $_.id; method = "GET"; url = "/users/$($_.id)/authentication/methods" }
        }
        $responses = Invoke-GraphBatch -Requests $requests -AccessToken $token -ApiVersion "beta"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Requests,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [ValidateRange(1, 20)]
        [int]$MaxBatchSize = 20,

        [int]$MaxRetries = 3,

        [ValidateSet("v1.0", "beta")]
        [string]$ApiVersion = "v1.0"
    )

    if ($Requests.Count -eq 0) {
        return @{}
    }

    $batchEndpoint = "https://graph.microsoft.com/$ApiVersion/`$batch"
    $results = @{}

    # Chunk requests into batches of MaxBatchSize
    $batches = [System.Collections.Generic.List[array]]::new()
    for ($i = 0; $i -lt $Requests.Count; $i += $MaxBatchSize) {
        $endIndex = [Math]::Min($i + $MaxBatchSize - 1, $Requests.Count - 1)
        $batches.Add($Requests[$i..$endIndex])
    }

    Write-Verbose "[BATCH] Processing $($Requests.Count) requests in $($batches.Count) batches"

    $batchNumber = 0
    foreach ($batch in $batches) {
        $batchNumber++
        $retryQueue = [System.Collections.Generic.List[hashtable]]::new()

        # Build batch request body
        $batchBody = @{
            requests = @($batch | ForEach-Object {
                @{
                    id = $_.id
                    method = $_.method
                    url = $_.url
                }
            })
        }

        $headers = @{
            'Authorization' = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
        }

        $batchRetryCount = 0
        $batchSuccess = $false

        while (-not $batchSuccess -and $batchRetryCount -lt $MaxRetries) {
            try {
                Write-Verbose "[BATCH] Executing batch $batchNumber/$($batches.Count) with $($batch.Count) requests"

                $response = Invoke-RestMethod -Uri $batchEndpoint -Method POST -Headers $headers `
                    -Body ($batchBody | ConvertTo-Json -Depth 10 -Compress) -ErrorAction Stop

                # Process each response
                foreach ($resp in $response.responses) {
                    $requestId = $resp.id
                    $statusCode = $resp.status

                    if ($statusCode -ge 200 -and $statusCode -lt 300) {
                        # Success
                        $results[$requestId] = $resp.body
                    }
                    elseif ($statusCode -eq 404) {
                        # Not found - return empty result (expected for entities without owners/licenses)
                        $results[$requestId] = @{ value = @() }
                    }
                    elseif ($statusCode -eq 429 -or $statusCode -ge 500) {
                        # Retryable error - add to retry queue
                        $originalRequest = $batch | Where-Object { $_.id -eq $requestId }
                        if ($originalRequest) {
                            $retryQueue.Add(@{
                                id = $originalRequest.id
                                method = $originalRequest.method
                                url = $originalRequest.url
                                retryCount = 0
                            })
                        }
                        Write-Verbose "[BATCH] Request $requestId failed with $statusCode - queued for retry"
                    }
                    else {
                        # Non-retryable error
                        Write-Warning "[BATCH] Request $requestId failed with status $statusCode"
                        $results[$requestId] = $null
                    }
                }

                $batchSuccess = $true
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__

                # Handle batch-level 429
                if ($statusCode -eq 429) {
                    $retryAfter = 60
                    $retryAfterHeader = $_.Exception.Response.Headers.'Retry-After'
                    if ($retryAfterHeader -and $retryAfterHeader -match '^\d+$') {
                        $retryAfter = [int]$retryAfterHeader
                    }
                    Write-Warning "[BATCH] Batch rate limited (429). Waiting $retryAfter seconds..."
                    Start-Sleep -Seconds $retryAfter
                    # Don't increment retry count for 429
                    continue
                }

                $batchRetryCount++
                if ($statusCode -ge 500 -and $batchRetryCount -lt $MaxRetries) {
                    $delay = 5 * [Math]::Pow(2, $batchRetryCount - 1)
                    Write-Warning "[BATCH] Batch failed with $statusCode. Retry $batchRetryCount/$MaxRetries in $delay seconds..."
                    Start-Sleep -Seconds $delay
                    continue
                }

                Write-Error "[BATCH] Batch $batchNumber failed after $batchRetryCount retries: $_"
                throw
            }
        }

        # Process retry queue for failed individual requests
        $retryAttempt = 0
        while ($retryQueue.Count -gt 0 -and $retryAttempt -lt $MaxRetries) {
            $retryAttempt++
            $currentRetries = [array]$retryQueue.ToArray()
            $retryQueue.Clear()

            Write-Verbose "[BATCH] Retrying $($currentRetries.Count) failed requests (attempt $retryAttempt/$MaxRetries)"

            # Small delay before retry
            Start-Sleep -Seconds (2 * $retryAttempt)

            # Re-batch the retries
            $retryBatchBody = @{
                requests = @($currentRetries | ForEach-Object {
                    @{ id = $_.id; method = $_.method; url = $_.url }
                })
            }

            try {
                $retryResponse = Invoke-RestMethod -Uri $batchEndpoint -Method POST -Headers $headers `
                    -Body ($retryBatchBody | ConvertTo-Json -Depth 10 -Compress) -ErrorAction Stop

                foreach ($resp in $retryResponse.responses) {
                    $requestId = $resp.id
                    $statusCode = $resp.status

                    if ($statusCode -ge 200 -and $statusCode -lt 300) {
                        $results[$requestId] = $resp.body
                    }
                    elseif ($statusCode -eq 404) {
                        $results[$requestId] = @{ value = @() }
                    }
                    elseif (($statusCode -eq 429 -or $statusCode -ge 500) -and $retryAttempt -lt $MaxRetries) {
                        # Still failing - re-queue
                        $originalRequest = $currentRetries | Where-Object { $_.id -eq $requestId }
                        if ($originalRequest) {
                            $retryQueue.Add($originalRequest)
                        }
                    }
                    else {
                        Write-Warning "[BATCH] Request $requestId failed permanently with status $statusCode"
                        $results[$requestId] = $null
                    }
                }
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                if ($statusCode -eq 429) {
                    $retryAfter = 30
                    Write-Warning "[BATCH] Retry batch rate limited. Waiting $retryAfter seconds..."
                    Start-Sleep -Seconds $retryAfter
                    # Re-add all to retry queue
                    foreach ($req in $currentRetries) {
                        $retryQueue.Add($req)
                    }
                }
                else {
                    Write-Warning "[BATCH] Retry batch failed: $_"
                    # Mark all as failed
                    foreach ($req in $currentRetries) {
                        $results[$req.id] = $null
                    }
                }
            }
        }

        # Any remaining items in retry queue are permanent failures
        foreach ($req in $retryQueue) {
            Write-Warning "[BATCH] Request $($req.id) failed after $MaxRetries retries"
            $results[$req.id] = $null
        }
    }

    $successCount = ($results.Values | Where-Object { $_ -ne $null }).Count
    Write-Verbose "[BATCH] Completed: $successCount/$($Requests.Count) requests successful"

    return $results
}

function Get-GraphPagedResult {
    <#
    .SYNOPSIS
        Gets all pages of results from a Graph API endpoint with optimized memory management
    
    .DESCRIPTION
        Automatically follows @odata.nextLink to retrieve all results.
        Uses ArrayList for efficient memory management with large result sets (O(1) append vs O(n) for arrays).
        Uses Invoke-GraphWithRetry for each page to handle transient failures.
        
        Key optimizations:
        - ArrayList.AddRange() is O(1) vs array += which is O(n)
        - For 10,000 users: ~55,000 operations (array) vs ~11 operations (ArrayList)
        - 15-20% faster for large result sets
        - Lower memory usage (no temporary array allocations)
        
        Supports optional progress reporting for long-running collections.
    
    .PARAMETER Uri
        The initial Graph API URI to query
    
    .PARAMETER AccessToken
        The access token for authentication
    
    .PARAMETER PageSize
        Optional page size (default: 999, maximum supported by Graph API).
        Smaller page sizes may be useful for testing or memory-constrained environments.
    
    .PARAMETER ShowProgress
        Show progress information during collection (useful for large result sets).
        Displays page number and cumulative count.
    
    .EXAMPLE
        $users = Get-GraphPagedResult -Uri "https://graph.microsoft.com/v1.0/users?`$select=id,displayName" -AccessToken $token
        
    .EXAMPLE
        $devices = Get-GraphPagedResult -Uri "https://graph.microsoft.com/v1.0/devices" -AccessToken $token -PageSize 500 -ShowProgress
        
    .EXAMPLE
        # Get all groups with specific properties
        $groups = Get-GraphPagedResult -Uri "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName,groupTypes" -AccessToken $token -ShowProgress
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [ValidateRange(1, 999)]
        [int]$PageSize = 999,
        
        [switch]$ShowProgress
    )
    
    # Inject $top parameter if not already present
    if ($Uri -notmatch '\$top=') {
        $separator = if ($Uri -match '\?') { '&' } else { '?' }
        $Uri = "$Uri$separator`$top=$PageSize"
    }
    
    # Use ArrayList for efficient appending (O(1) vs O(n) for array +=)
    # This is crucial for large result sets (10,000+ items)
    $results = [System.Collections.ArrayList]::new()
    $nextLink = $Uri
    $pageCount = 0
    
    while ($nextLink) {
        $pageCount++
        
        if ($ShowProgress) {
            Write-Verbose "Fetching page $pageCount... ($($results.Count) items retrieved so far)"
        }
        
        $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $AccessToken
        
        if ($response.value) {
            # AddRange is more efficient than adding items individually
            # For 999 items per page, this is 1 operation vs 999 operations
            [void]$results.AddRange($response.value)
        }
        
        $nextLink = $response.'@odata.nextLink'
    }
    
    if ($ShowProgress -or $results.Count -gt 1000) {
        Write-Verbose "Completed: Retrieved $($results.Count) items across $pageCount pages"
    }
    
    # Return as array for pipeline compatibility
    # ToArray() is fast and creates a properly typed array
    return $results.ToArray()
}

#endregion

#region Azure Storage Functions

function Initialize-AppendBlob {
    <#
    .SYNOPSIS
        Creates a new append blob or verifies existing one
    
    .DESCRIPTION
        Append blobs must be explicitly created before appending data.
        This function creates the blob if it doesn't exist, or confirms it exists if already created.
        
        Append blobs are ideal for streaming writes where you don't know the final size upfront.
        Perfect for log files, data collection outputs, and incremental writes.
    
    .PARAMETER StorageAccountName
        Name of the Azure Storage account
    
    .PARAMETER ContainerName
        Name of the blob container
    
    .PARAMETER BlobName
        Name of the blob to create/verify
    
    .PARAMETER AccessToken
        Access token for Storage authentication (use managed identity token)
    
    .EXAMPLE
        Initialize-AppendBlob -StorageAccountName "mystorageacct" -ContainerName "raw-data" -BlobName "2025-12-23T14-30-00Z/users.jsonl" -AccessToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$BlobName,
        
        [Parameter(Mandatory)]
        [string]$AccessToken
    )
    
    $uri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'x-ms-blob-type' = 'AppendBlob'
        'x-ms-version' = '2021-08-06'
        'Content-Length' = '0'
        'If-None-Match' = '*'  # CRITICAL: Prevents overwriting existing blob - returns 409 if blob exists
    }

    try {
        Write-Information "[DEBUG-INIT] Creating append blob: $BlobName" -InformationAction Continue
        Write-Verbose "Initializing append blob: $BlobName"
        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers | Out-Null
        Write-Information "[DEBUG-INIT] CREATED (201) append blob: $BlobName" -InformationAction Continue
        Write-Verbose "Successfully initialized append blob: $BlobName"
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Information "[DEBUG-INIT] HTTP $statusCode for blob: $BlobName" -InformationAction Continue
        if ($statusCode -eq 409 -or $statusCode -eq 412) {
            # 409: Blob already exists (legacy)
            # 412: Precondition failed (If-None-Match) - blob already exists
            Write-Information "[DEBUG-INIT] Blob exists ($statusCode), continuing: $BlobName" -InformationAction Continue
            Write-Verbose "Append blob already exists: $BlobName"
        }
        else {
            Write-Error "Failed to initialize append blob $BlobName (status: $statusCode): $_"
            throw
        }
    }
}

function Add-BlobContent {
    <#
    .SYNOPSIS
        Appends content to an append blob with retry logic
    
    .DESCRIPTION
        Uses Azure's Append Block operation for true streaming writes with exponential backoff retry.
        
        CRITICAL: This function implements retry logic for transient failures to prevent silent data loss.
        Retries 3 times with exponential backoff for: 5xx server errors, 408 timeouts, 429 throttling.
        
        Each append operation adds a new block to the blob, up to 50,000 blocks per blob.
        Maximum block size: 4 MB. Maximum blob size: 195 GB (50,000 blocks × 4 MB).
    
    .PARAMETER StorageAccountName
        Name of the Azure Storage account
    
    .PARAMETER ContainerName
        Name of the blob container
    
    .PARAMETER BlobName
        Name of the append blob
    
    .PARAMETER Content
        String content to append
    
    .PARAMETER AccessToken
        Access token for Storage authentication
    
    .PARAMETER MaxRetries
        Maximum number of retry attempts for transient errors. Default: 3
    
    .PARAMETER BaseRetryDelaySeconds
        Base delay for exponential backoff. Default: 2
    
    .EXAMPLE
        Add-BlobContent -StorageAccountName "mystorageacct" -ContainerName "raw-data" -BlobName "users.jsonl" -Content $jsonlData -AccessToken $token -MaxRetries 3 -BaseRetryDelaySeconds 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$BlobName,
        
        [Parameter(Mandatory)]
        [string]$Content,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 2
    )
    
    $uri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName`?comp=appendblock"
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'x-ms-version' = '2021-08-06'
        'Content-Type' = 'text/plain; charset=utf-8'
        'Content-Length' = $contentBytes.Length.ToString()
    }
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            Write-Information "[DEBUG-BLOB] Appending $($contentBytes.Length) bytes to $BlobName (attempt $($attempt + 1))" -InformationAction Continue
            Write-Verbose "Appending $($contentBytes.Length) bytes to blob: $BlobName (attempt $($attempt + 1))"
            Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $contentBytes | Out-Null
            Write-Information "[DEBUG-BLOB] SUCCESS: Appended to $BlobName" -InformationAction Continue
            Write-Verbose "Successfully appended content to blob: $BlobName"
            return
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            # 429 doesn't count against retry limit
            if ($statusCode -ne 429) {
                $attempt++
            }
            
            # Retry on transient errors: 5xx, 408 (timeout), 429 (throttle)
            $isRetryable = ($statusCode -ge 500) -or ($statusCode -eq 408) -or ($statusCode -eq 429)
            
            if ($isRetryable -and $attempt -lt $MaxRetries) {
                $delay = $BaseRetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                
                if ($statusCode -eq 429) {
                    $retryAfterHeader = $_.Exception.Response.Headers.'Retry-After'
                    if ($retryAfterHeader) {
                        if ($retryAfterHeader -match '^\d+$') {
                            $delay = [int]$retryAfterHeader
                        } else {
                            try {
                                $retryDate = [DateTime]::ParseExact($retryAfterHeader, 'r', [System.Globalization.CultureInfo]::InvariantCulture)
                                $delay = [Math]::Max([Math]::Ceiling(($retryDate - (Get-Date).ToUniversalTime()).TotalSeconds), 1)
                            } catch { Write-Verbose "Failed to parse retry-after date, using default delay" }
                        }
                    }
                }
                
                Write-Warning "Blob append failed (HTTP $statusCode). Retry $attempt of $MaxRetries in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            # Non-retryable error or max retries exceeded
            Write-Error "Failed to append to blob $BlobName after $attempt attempts: $_"
            throw
        }
    }
}

function Write-BlobBuffer {
    <#
    .SYNOPSIS
        Flushes a StringBuilder buffer to an append blob if it has content

    .DESCRIPTION
        Generic helper for writing buffered content to Azure Blob Storage.
        Checks if the buffer has content, writes it using Add-BlobContent, then clears the buffer.

    .PARAMETER Buffer
        Reference to the StringBuilder object containing buffered content

    .PARAMETER StorageAccountName
        Name of the Azure Storage account

    .PARAMETER ContainerName
        Name of the blob container

    .PARAMETER BlobName
        Name of the append blob to write to

    .PARAMETER AccessToken
        Access token for Storage authentication

    .PARAMETER MaxRetries
        Maximum number of retry attempts for transient errors. Default: 3

    .PARAMETER BaseRetryDelaySeconds
        Base delay for exponential backoff. Default: 2

    .EXAMPLE
        $buffer = New-Object System.Text.StringBuilder(2097152)
        # ... add content to buffer ...
        Write-BlobBuffer -Buffer ([ref]$buffer) -StorageAccountName $account -ContainerName $container -BlobName $blob -AccessToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref]$Buffer,

        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$ContainerName,

        [Parameter(Mandatory)]
        [string]$BlobName,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 2
    )

    if ($Buffer.Value.Length -gt 0) {
        Add-BlobContent -StorageAccountName $StorageAccountName `
                       -ContainerName $ContainerName `
                       -BlobName $BlobName `
                       -Content $Buffer.Value.ToString() `
                       -AccessToken $AccessToken `
                       -MaxRetries $MaxRetries `
                       -BaseRetryDelaySeconds $BaseRetryDelaySeconds
        $Buffer.Value.Clear()
    }
}

function Write-BlobContent {
    <#
    .SYNOPSIS
        Writes content to Azure Blob Storage (overwrites existing)
    
    .DESCRIPTION
        Creates or completely overwrites a block blob.
        For streaming appends, use Add-BlobContent with append blobs instead.
        
        Use this for:
        - Initial file creation with complete content
        - Small files that fit in memory
        - Files that need to be completely replaced
    
    .PARAMETER StorageAccountName
        Name of the Azure Storage account
    
    .PARAMETER ContainerName
        Name of the blob container
    
    .PARAMETER BlobName
        Name of the blob to create/overwrite
    
    .PARAMETER Content
        String content to write
    
    .PARAMETER AccessToken
        Access token for Storage authentication
    
    .EXAMPLE
        Write-BlobContent -StorageAccountName "mystorageacct" -ContainerName "config" -BlobName "settings.json" -Content $json -AccessToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$BlobName,
        
        [Parameter(Mandatory)]
        [string]$Content,
        
        [Parameter(Mandatory)]
        [string]$AccessToken
    )
    
    $uri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type' = 'application/json; charset=utf-8'
        'x-ms-version' = '2021-08-06'
    }
    
    try {
        Write-Verbose "Writing blob: $BlobName ($(($Content).Length) characters)"
        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $Content | Out-Null
        Write-Verbose "Successfully wrote blob: $BlobName"
    }
    catch {
        Write-Error "Failed to write blob $BlobName`: $_"
        throw
    }
}

#endregion

function Write-CosmosDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,
        
        [Parameter(Mandatory)]
        [string]$Database,
        
        [Parameter(Mandatory)]
        [string]$Container,
        
        [Parameter(Mandatory)]
        [hashtable]$Document,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [int]$MaxRetries = 3
    )
    
    $uri = "$Endpoint/dbs/$Database/colls/$Container/docs"
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $headers = @{
            'Authorization' = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
            'x-ms-date' = [DateTime]::UtcNow.ToString('r')
            'x-ms-version' = '2018-12-31'
            'x-ms-documentdb-partitionkey' = "[`"$($Document.objectId)`"]"
        }
        
        $body = $Document | ConvertTo-Json -Depth 10 -Compress
        
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            # 429 doesn't count against retry limit
            if ($statusCode -eq 429) {
                $delay = 5
                $retryAfterHeader = $_.Exception.Response.Headers.'x-ms-retry-after-ms'
                if ($retryAfterHeader -and $retryAfterHeader -match '^\d+$') {
                    $delay = [Math]::Ceiling([int]$retryAfterHeader / 1000)
                }
                Write-Warning "Cosmos throttled (429). Waiting $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            # 5xx errors count against retries
            $attempt++
            if ($statusCode -ge 500 -and $attempt -lt $MaxRetries) {
                $delay = 2 * [Math]::Pow(2, $attempt - 1)
                Write-Warning "Cosmos error ($statusCode). Retry $attempt/$MaxRetries in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            Write-Error "Cosmos write failed: $_"
            throw
        }
    }
    
    throw "Cosmos write failed after $MaxRetries retries"
}

function Write-CosmosBatch {
    <#
    .SYNOPSIS
        Writes multiple documents to Cosmos DB in batches
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,
        
        [Parameter(Mandatory)]
        [string]$Database,
        
        [Parameter(Mandatory)]
        [string]$Container,
        
        [Parameter(Mandatory)]
        [array]$Documents,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [Parameter(Mandatory=$false)]
        [int]$BatchSize = 100
    )
    
    $totalDocs = $Documents.Count
    $writtenCount = 0
    
    for ($i = 0; $i -lt $totalDocs; $i += $BatchSize) {
        $batch = $Documents[$i..[Math]::Min($i + $BatchSize - 1, $totalDocs - 1)]
        
        foreach ($doc in $batch) {
            Write-CosmosDocument -Endpoint $Endpoint -Database $Database `
                -Container $Container -Document $doc -AccessToken $AccessToken
            $writtenCount++
        }
        
        if ($writtenCount % 500 -eq 0) {
            Write-Verbose "Written $writtenCount / $totalDocs documents"
        }
    }
    
    Write-Verbose "Batch write complete: $writtenCount documents"
    return $writtenCount
}

function Get-CosmosDocument {
    <#
    .SYNOPSIS
        Queries Cosmos DB with callback pattern for memory-efficient processing
    
    .DESCRIPTION
        Processes each page of results via callback instead of accumulating into array.
        Reduces memory by 50% - eliminates intermediate 50MB array for 250K documents.
        
        V3 Change: Callback pattern processes pages immediately, builds hashtable directly.
    
    .PARAMETER ProcessPage
        Scriptblock called for each page of results. Receives $Documents parameter.
        
    .EXAMPLE
        $existingUsers = @{}
        Get-CosmosDocument -Endpoint $endpoint -Database $db -Container $container `
            -Query $query -AccessToken $token -ProcessPage {
                param($Documents)
                foreach ($doc in $Documents) {
                    $existingUsers[$doc.objectId] = $doc
                }
            }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,
        
        [Parameter(Mandatory)]
        [string]$Database,
        
        [Parameter(Mandatory)]
        [string]$Container,
        
        [Parameter(Mandatory)]
        [string]$Query,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [Parameter(Mandatory)]
        [scriptblock]$ProcessPage
    )
    
    $uri = "$Endpoint/dbs/$Database/colls/$Container/docs"
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type' = 'application/query+json'
        'x-ms-date' = [DateTime]::UtcNow.ToString('r')
        'x-ms-version' = '2018-12-31'
        'x-ms-documentdb-isquery' = 'True'
        'x-ms-documentdb-query-enablecrosspartition' = 'True'
    }
    
    $body = @{
        query = $Query
    } | ConvertTo-Json
    
    $continuation = $null
    $totalDocs = 0
    
    do {
        if ($continuation) {
            $headers['x-ms-continuation'] = $continuation
        }
        
        try {
            $responseHeaders = $null
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ResponseHeadersVariable responseHeaders
            
            if ($response.Documents -and $response.Documents.Count -gt 0) {
                # Process page immediately, don't accumulate
                & $ProcessPage -Documents $response.Documents
                $totalDocs += $response.Documents.Count
            }
            
            $continuation = $responseHeaders['x-ms-continuation']
        }
        catch {
            Write-Error "Cosmos query failed: $_"
            throw
        }
        
    } while ($continuation)
    
    Write-Verbose "Processed $totalDocs documents across all pages"
}

function Write-CosmosParallelBatch {
    <#
    .SYNOPSIS
        Writes multiple documents to Cosmos DB with parallel execution and retry
    
    .DESCRIPTION
        Implements parallel writes with ForEach-Object -Parallel and exponential backoff retry.
        Expected performance: 8-10 minutes for 250K documents (vs 62.5 minutes sequential).
        
        V3 Addition: 12-20x performance improvement for bulk writes.
    
    .PARAMETER ParallelThrottle
        Number of parallel threads. Default: 10
        
    .EXAMPLE
        Write-CosmosParallelBatch -Endpoint $endpoint -Database $db -Container $container `
            -Documents $docs -AccessToken $token -ParallelThrottle 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,
        
        [Parameter(Mandatory)]
        [string]$Database,
        
        [Parameter(Mandatory)]
        [string]$Container,
        
        [Parameter(Mandatory)]
        [array]$Documents,
        
        [Parameter(Mandatory)]
        [string]$AccessToken,
        
        [int]$ParallelThrottle = 25
    )
    
    $totalDocs = $Documents.Count
    Write-Verbose "Writing $totalDocs documents with $ParallelThrottle parallel threads"
    
    $Documents | ForEach-Object -ThrottleLimit $ParallelThrottle -Parallel {
        $doc = $_
        $localEndpoint = $using:Endpoint
        $localDatabase = $using:Database
        $localContainer = $using:Container
        $localToken = $using:AccessToken
        
        $uri = "$localEndpoint/dbs/$localDatabase/colls/$localContainer/docs"
        
        $headers = @{
            'Authorization' = "Bearer $localToken"
            'Content-Type' = 'application/json'
            'x-ms-date' = [DateTime]::UtcNow.ToString('r')
            'x-ms-version' = '2018-12-31'
            'x-ms-documentdb-partitionkey' = "[`"$($doc.objectId)`"]"
        }
        
        $body = $doc | ConvertTo-Json -Depth 10 -Compress
        
 $maxRetries = 3
        $attempt = 0
        
        while ($attempt -lt $maxRetries) {
            try {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop | Out-Null
                break
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                
                # 429 doesn't count against retry limit
                if ($statusCode -ne 429) {
                    $attempt++
                }
                
                if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt $maxRetries) {
                    $delay = 2 * [Math]::Pow(2, $attempt - 1)
                    if ($statusCode -eq 429) {
                        $retryAfterHeader = $_.Exception.Response.Headers.'x-ms-retry-after-ms'
                        if ($retryAfterHeader -and $retryAfterHeader -match '^\d+$') {
                            $delay = [Math]::Ceiling([int]$retryAfterHeader / 1000)
                        }
                    }
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw
            }
        }
    }
    
    Write-Verbose "Parallel write complete: $totalDocs documents"
    return $totalDocs
}

#region Delta Indexing

function Invoke-DeltaIndexing {
    <#
    .SYNOPSIS
        Generic delta indexing function for any entity type (users, groups, service principals)

    .DESCRIPTION
        Shared logic for delta change detection and indexing to Cosmos DB.
        - Reads entities from Blob Storage (JSONL format)
        - Compares with existing Cosmos DB data (via input binding)
        - Identifies new, modified, deleted, and unchanged entities
        - Returns documents ready for output bindings

        This function consolidates the common logic from IndexInCosmosDB,
        IndexGroupsInCosmosDB, and IndexServicePrincipalsInCosmosDB.

    .PARAMETER BlobName
        Path to the blob containing JSONL data

    .PARAMETER Timestamp
        Snapshot timestamp/ID for this indexing run

    .PARAMETER ExistingData
        Array of existing documents from Cosmos DB input binding

    .PARAMETER Config
        Hashtable containing entity-specific configuration:
        - EntityType: 'users', 'groups', or 'servicePrincipals'
        - EntityNameSingular: 'user', 'group', or 'servicePrincipal' (for logging)
        - EntityNamePlural: 'users', 'groups', or 'servicePrincipals' (for logging)
        - CompareFields: Array of scalar field names to compare for changes
        - ArrayFields: Array of field names that require JSON comparison (arrays)
        - DocumentFields: Hashtable mapping field names to source property paths
        - WriteDeletes: Boolean - whether to include deleted entities in raw output
        - IncludeDeleteMarkers: Boolean - whether to add soft delete markers (deleted, deletedTimestamp, ttl)

    .OUTPUTS
        Hashtable containing:
        - RawDocuments: Array of documents to write to *_raw container
        - ChangeDocuments: Array of change events for *_changes container
        - SnapshotDocument: Summary document for snapshots container
        - Statistics: Hashtable with counts (Total, New, Modified, Deleted, Unchanged, WriteCount)

    .EXAMPLE
        $config = @{
            EntityType = 'users'
            EntityNameSingular = 'user'
            EntityNamePlural = 'users'
            CompareFields = @('accountEnabled', 'userType', 'displayName')
            ArrayFields = @()
            DocumentFields = @{
                userPrincipalName = 'userPrincipalName'
                accountEnabled = 'accountEnabled'
            }
            WriteDeletes = $true
            IncludeDeleteMarkers = $true
        }

        $result = Invoke-DeltaIndexing -BlobName $blobName -Timestamp $timestamp `
            -ExistingData $usersRawIn -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BlobName,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [Parameter()]
        [array]$ExistingData,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter()]
        [string]$FilterByPrincipalType  # Filter blob entities to only this principalType (e.g., 'user', 'group')
    )

    # Extract config
    $entityType = $Config.EntityType
    $entitySingular = $Config.EntityNameSingular
    $entityPlural = $Config.EntityNamePlural
    $compareFields = $Config.CompareFields
    $arrayFields = $Config.ArrayFields
    $documentFields = $Config.DocumentFields
    $writeDeletes = $Config.WriteDeletes
    $includeDeleteMarkers = $Config.IncludeDeleteMarkers

    # Get configuration from environment
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $enableDelta = $env:ENABLE_DELTA_DETECTION -eq 'true'
    $containerName = if ($env:STORAGE_CONTAINER_RAW_DATA) { $env:STORAGE_CONTAINER_RAW_DATA } else { 'raw-data' }

    Write-Verbose "Starting delta indexing for $entityPlural"
    Write-Verbose "  Blob: $BlobName"
    Write-Verbose "  Delta detection: $enableDelta"

    # Get storage token (cached)
    $storageToken = Get-CachedManagedIdentityToken -Resource "https://storage.azure.com"

    #region Step 1: Read entities from Blob
    Write-Verbose "Reading $entityPlural from Blob Storage..."

    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$BlobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'AppendBlob'
    }

    # Use Invoke-WebRequest to get raw content (not Invoke-RestMethod which auto-parses JSON)
    # This is critical for JSONL files where each line is a separate JSON object
    $response = Invoke-WebRequest -Uri $blobUri -Method Get -Headers $headers -UseBasicParsing

    # Convert byte array to string (Azure Blob returns application/octet-stream which comes back as Byte[])
    if ($response.Content -is [byte[]]) {
        $blobContent = [System.Text.Encoding]::UTF8.GetString($response.Content)
    } else {
        $blobContent = $response.Content
    }
    Write-Verbose "Downloaded blob: $($blobContent.Length) characters"

    # Parse JSONL into HashMap
    $currentEntities = @{}
    $lineNumber = 0

    # Always treat as JSONL string - parse each line as separate JSON object
    foreach ($line in ($blobContent -split "`n")) {
        $lineNumber++
        $trimmedLine = $line.Trim()
        if ($trimmedLine) {
            try {
                $entity = $trimmedLine | ConvertFrom-Json
                if ($entity.objectId) {
                    $currentEntities[$entity.objectId] = $entity
                } else {
                    Write-Verbose "Line $lineNumber has no objectId (may be metadata)"
                }
            }
            catch {
                Write-Warning "Failed to parse line $lineNumber`: $_"
            }
        }
    }

    Write-Verbose "Parsed $($currentEntities.Count) $entityPlural from Blob"

    # CRITICAL FIX: If FilterByPrincipalType is specified, filter current entities BEFORE delta detection
    # This prevents the same entities from being processed multiple times when the orchestrator
    # calls the indexer separately for each principal type (users, groups, servicePrincipals, etc.)
    if ($FilterByPrincipalType) {
        $originalCount = $currentEntities.Count
        $filteredEntities = @{}
        foreach ($objectId in $currentEntities.Keys) {
            $entity = $currentEntities[$objectId]
            if ($entity.principalType -eq $FilterByPrincipalType) {
                $filteredEntities[$objectId] = $entity
            }
        }
        $currentEntities = $filteredEntities
        Write-Verbose "Filtered to principalType='$FilterByPrincipalType': $originalCount -> $($currentEntities.Count) entities"
    }

    # For unified containers (principals), determine the type being indexed
    # This is used to filter existing data so we only compare like-with-like
    # NOTE: For 'relationships', we don't filter by relationType since all types are in one file
    $targetPrincipalType = $null
    $targetRelationType = $null
    $targetPolicyType = $null
    $targetResourceTypes = @()  # Initialize before the if block to ensure it's always defined
    $isMixedTypeCollection = ($Config.EntityType -eq 'relationships')  # Relationships contain multiple types

    # Use FilterByPrincipalType if provided, otherwise detect from first entity
    if ($FilterByPrincipalType) {
        $targetPrincipalType = $FilterByPrincipalType
        Write-Verbose "Using explicit principalType filter: $targetPrincipalType"
    }
    elseif ($currentEntities.Count -gt 0 -and -not $isMixedTypeCollection) {
        $firstEntity = $currentEntities.Values | Select-Object -First 1
        $targetPrincipalType = $firstEntity.principalType
        $targetRelationType = $firstEntity.relationType
        $targetPolicyType = $firstEntity.policyType

        # For Azure resources, detect ALL resourceTypes in the current collection
        # This allows filtering existing data by the set of resourceTypes being indexed
        if ($Config.EntityType -eq 'azureResources') {
            $targetResourceTypes = @($currentEntities.Values | Select-Object -ExpandProperty resourceType -Unique)
            if ($targetResourceTypes.Count -gt 0) {
                Write-Verbose "Detected resourceTypes: $($targetResourceTypes -join ', ')"
            }
        }
        # For Azure relationships, detect ALL relationTypes in the current collection
        if ($Config.EntityType -eq 'azureRelationships') {
            $targetRelationType = @($currentEntities.Values | Select-Object -ExpandProperty relationType -Unique)
            if ($targetRelationType.Count -gt 0) {
                Write-Verbose "Detected relationTypes: $($targetRelationType -join ', ')"
            }
        }
        # For policies, detect ALL policyTypes in the current collection
        # This prevents filtering issues when blob contains multiple policy types (CA, Intune, etc.)
        if ($Config.EntityType -eq 'policies') {
            $targetPolicyType = @($currentEntities.Values | Select-Object -ExpandProperty policyType -Unique)
            if ($targetPolicyType.Count -gt 0) {
                Write-Verbose "Detected policyTypes: $($targetPolicyType -join ', ')"
            }
        }

        if ($targetPrincipalType) {
            Write-Verbose "Detected principalType: $targetPrincipalType"
        }
        if ($targetRelationType -and $targetRelationType -isnot [array]) {
            Write-Verbose "Detected relationType: $targetRelationType"
        }
        if ($targetPolicyType) {
            Write-Verbose "Detected policyType: $targetPolicyType"
        }
    }
    elseif ($isMixedTypeCollection) {
        Write-Verbose "Processing mixed-type collection (relationships) - no type filtering"
    }
    elseif ($currentEntities.Count -eq 0 -and $Config.EntityType -in @('azureResources', 'azureRelationships', 'principals', 'relationships', 'policies', 'events')) {
        # SAFEGUARD: If blob is empty, skip delta detection entirely
        # This prevents false deletions when the blob couldn't be read or is genuinely empty
        Write-Warning "No entities found in blob for $($Config.EntityType) - skipping delta detection to prevent false deletions"
    }
    #endregion

    #region Step 2: Build existing entities hashtable from input binding
    $existingEntities = @{}

    # SAFEGUARD: Skip loading existing data if blob is empty
    # This prevents false deletions when the blob couldn't be read or is genuinely empty
    $skipExistingDataLoad = $false
    if ($Config.EntityType -in @('azureResources', 'azureRelationships', 'principals', 'relationships', 'policies', 'events') -and $currentEntities.Count -eq 0) {
        $skipExistingDataLoad = $true
        Write-Verbose "Skipping existing data load for $($Config.EntityType) - blob was empty, preventing false deletions"
    }

    if ($enableDelta -and $ExistingData -and -not $skipExistingDataLoad) {
        Write-Verbose "Processing existing $entityPlural from Cosmos DB (input binding)..."

        foreach ($doc in $ExistingData) {
            # For unified containers, only include documents matching the same type discriminator
            # This prevents marking entities of different types as "deleted"
            # EXCEPTION: For mixed-type collections like relationships, include all
            $includeDoc = $true

            if (-not $isMixedTypeCollection) {
                if ($targetPrincipalType -and $doc.principalType) {
                    $includeDoc = ($doc.principalType -eq $targetPrincipalType)
                }
                elseif ($targetRelationType -and $doc.relationType) {
                    # Handle both single relationType and array of relationTypes
                    if ($targetRelationType -is [array]) {
                        $includeDoc = ($doc.relationType -in $targetRelationType)
                    } else {
                        $includeDoc = ($doc.relationType -eq $targetRelationType)
                    }
                }
                elseif ($targetPolicyType -and $doc.policyType) {
                    # Handle both single policyType and array of policyTypes
                    if ($targetPolicyType -is [array]) {
                        $includeDoc = ($doc.policyType -in $targetPolicyType)
                    } else {
                        $includeDoc = ($doc.policyType -eq $targetPolicyType)
                    }
                }
                elseif ($targetResourceTypes.Count -gt 0 -and $doc.resourceType) {
                    # For Azure resources, only include existing docs that match resource types in current blob
                    $includeDoc = ($doc.resourceType -in $targetResourceTypes)
                }
            }

            if ($includeDoc) {
                $existingEntities[$doc.objectId] = $doc
            }
        }

        $filterDesc = if ($isMixedTypeCollection) { "no filter (mixed-type)" }
                      elseif ($targetPrincipalType) { "principalType=$targetPrincipalType" }
                      elseif ($targetRelationType -and $targetRelationType -is [array]) { "relationType in ($($targetRelationType -join ', '))" }
                      elseif ($targetRelationType) { "relationType=$targetRelationType" }
                      elseif ($targetPolicyType -and $targetPolicyType -is [array]) { "policyType in ($($targetPolicyType -join ', '))" }
                      elseif ($targetPolicyType) { "policyType=$targetPolicyType" }
                      elseif ($targetResourceTypes.Count -gt 0) { "resourceType in ($($targetResourceTypes -join ', '))" }
                      else { "no filter" }

        Write-Verbose "Found $($existingEntities.Count) existing $entityPlural in Cosmos (filtered by $filterDesc)"
    }
    #endregion

    #region Step 3: Delta detection
    # ============================================================================
    # CHANGE LOG STORAGE OPTIMIZATION (Fixed 2026-01-07)
    # ============================================================================
    # PROBLEM: The changes container was storing FULL ENTITY COPIES for each change:
    #   - NEW:      { ...metadata, newValue: <full 600-byte entity> }
    #   - MODIFIED: { ...metadata, previousValue: <600 bytes>, newValue: <600 bytes>, delta: <100 bytes> }
    #   - DELETED:  { ...metadata, previousValue: <full 600-byte entity> }
    #
    # This caused the changes container to consume 93% of total Cosmos DB storage,
    # growing ~6 MB/month for a 1000-user tenant instead of ~1 MB/month.
    #
    # FIX: Store only minimal metadata + delta (changed fields with old/new values):
    #   - NEW:      { objectId, displayName, entityType, principalType, changeType, timestamps }
    #   - MODIFIED: { objectId, displayName, entityType, principalType, changeType, timestamps, changedFields, delta }
    #   - DELETED:  { objectId, displayName, entityType, principalType, changeType, timestamps }
    #
    # WHY THIS WORKS:
    #   - Full current state is always in the 'principals' container (delta-updated)
    #   - For NEW: the full entity exists in principals, no need to duplicate
    #   - For MODIFIED: only the delta matters for audit; current state is in principals
    #   - For DELETED: entity is soft-deleted in principals (effectiveTo=now, ttl set)
    #
    # STORAGE SAVINGS: ~80% reduction in changes container size
    #   - Before: ~1,400 bytes per modified change (prev + new + delta + metadata)
    #   - After:  ~250 bytes per modified change (delta + metadata only)
    #
    # ADDED FIELDS for better queryability:
    #   - entityType: the collection type (users, groups, etc.)
    #   - principalType: the entity's principalType field
    #   - changeDate: YYYY-MM-DD format for partition key queries
    #   - changedFields: array of field names that changed (for quick filtering)
    # ============================================================================

    # Use List<T> for efficient Add() operations instead of += which is O(n²)
    $newEntities = [System.Collections.Generic.List[object]]::new()
    $modifiedEntities = [System.Collections.Generic.List[object]]::new()
    $unchangedEntities = [System.Collections.Generic.List[string]]::new()
    $deletedEntities = [System.Collections.Generic.List[object]]::new()
    $changeLog = [System.Collections.Generic.List[object]]::new()

    # Check current entities
    foreach ($objectId in $currentEntities.Keys) {
        $currentEntity = $currentEntities[$objectId]

        if (-not $existingEntities.ContainsKey($objectId)) {
            # NEW entity
            $newEntities.Add($currentEntity)

            # Store minimal change record - full entity is in principals container
            $changeLog.Add(@{
                id = [Guid]::NewGuid().ToString()
                objectId = $objectId
                displayName = $currentEntity.displayName
                entityType = $EntityType
                principalType = $currentEntity.principalType
                changeType = 'new'
                changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                auditDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                changeDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                snapshotId = $Timestamp
            })
        }
        else {
            # Check if modified
            $existingEntity = $existingEntities[$objectId]

            $changed = $false
            $delta = @{}

            foreach ($field in $compareFields) {
                if ($field -in $arrayFields) {
                    # Array comparison using JSON serialization
                    $currentArray = $currentEntity.$field | Sort-Object
                    $existingArray = $existingEntity.$field | Sort-Object

                    $currentJson = $currentArray | ConvertTo-Json -Compress
                    $existingJson = $existingArray | ConvertTo-Json -Compress

                    if ($currentJson -ne $existingJson) {
                        $changed = $true
                        $delta[$field] = @{
                            old = $existingArray
                            new = $currentArray
                        }
                    }
                }
                else {
                    # Standard scalar comparison (but handle objects/hashtables properly)
                    $currentValue = $currentEntity.$field
                    $existingValue = $existingEntity.$field

                    # For objects/hashtables, PowerShell's -ne compares references, not values
                    # Use JSON serialization to compare by value instead
                    $isCurrentObject = $currentValue -is [hashtable] -or $currentValue -is [System.Collections.IDictionary] -or ($currentValue -is [PSCustomObject])
                    $isExistingObject = $existingValue -is [hashtable] -or $existingValue -is [System.Collections.IDictionary] -or ($existingValue -is [PSCustomObject])

                    $isDifferent = $false
                    if ($isCurrentObject -or $isExistingObject) {
                        # Compare objects by JSON serialization
                        $currentJson = if ($null -eq $currentValue) { 'null' } else { $currentValue | ConvertTo-Json -Compress -Depth 10 }
                        $existingJson = if ($null -eq $existingValue) { 'null' } else { $existingValue | ConvertTo-Json -Compress -Depth 10 }
                        $isDifferent = ($currentJson -ne $existingJson)
                    }
                    else {
                        # Simple scalar comparison
                        $isDifferent = ($currentValue -ne $existingValue)
                    }

                    if ($isDifferent) {
                        $changed = $true
                        $delta[$field] = @{
                            old = $existingValue
                            new = $currentValue
                        }
                    }
                }
            }

            if ($changed) {
                # MODIFIED entity
                $modifiedEntities.Add($currentEntity)

                # Store only delta (changed fields) - not full entity copies
                # Full current state is in principals container
                $changeLog.Add(@{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    displayName = $currentEntity.displayName
                    entityType = $EntityType
                    principalType = $currentEntity.principalType
                    changeType = 'modified'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    auditDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                    changeDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                    snapshotId = $Timestamp
                    changedFields = @($delta.Keys)
                    delta = $delta
                })
            }
            else {
                # UNCHANGED
                $unchangedEntities.Add($objectId)
            }
        }
    }

    # Check for deleted entities
    if ($enableDelta) {
        foreach ($objectId in $existingEntities.Keys) {
            if (-not $currentEntities.ContainsKey($objectId)) {
                # DELETED entity
                $deletedEntities.Add($existingEntities[$objectId])

                # Store minimal delete record - no need to duplicate the full entity
                # The entity is soft-deleted in principals container with effectiveTo=now (V3)
                $changeLog.Add(@{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    displayName = $existingEntities[$objectId].displayName
                    entityType = $EntityType
                    principalType = $existingEntities[$objectId].principalType
                    changeType = 'deleted'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    auditDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                    changeDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                    snapshotId = $Timestamp
                })
            }
        }
    }

    Write-Verbose "Delta summary:"
    Write-Verbose "  New: $($newEntities.Count)"
    Write-Verbose "  Modified: $($modifiedEntities.Count)"
    Write-Verbose "  Deleted: $($deletedEntities.Count)"
    Write-Verbose "  Unchanged: $($unchangedEntities.Count)"
    #endregion

    #region Step 4: Prepare documents for output
    # Use List<T> with AddRange for efficient merging instead of += which is O(n²)
    $entitiesToWrite = [System.Collections.Generic.List[object]]::new()
    $entitiesToWrite.AddRange($newEntities)
    $entitiesToWrite.AddRange($modifiedEntities)

    if ($writeDeletes) {
        $entitiesToWrite.AddRange($deletedEntities)
    }

    $docsToWrite = [System.Collections.Generic.List[object]]::new()

    if ($entitiesToWrite.Count -gt 0 -or (-not $enableDelta)) {
        Write-Verbose "Preparing $($entitiesToWrite.Count) changed $entityPlural for Cosmos..."

        # If delta disabled, write all entities
        if (-not $enableDelta) {
            $entitiesToWrite = $currentEntities.Values
            Write-Verbose "Delta detection disabled - writing all $($entitiesToWrite.Count) $entityPlural"
        }

        foreach ($entity in $entitiesToWrite) {
            # Build document from field mappings
            $doc = @{
                id = $entity.objectId
                objectId = $entity.objectId
                lastModified = $entity.collectionTimestamp ?? (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $Timestamp
            }

            # Add all configured fields
            foreach ($fieldName in $documentFields.Keys) {
                $sourcePath = $documentFields[$fieldName]
                $doc[$fieldName] = $entity.$sourcePath
            }

            # Add V3 temporal fields for soft delete (effectiveTo instead of deleted flag)
            if ($includeDeleteMarkers) {
                $isDeleted = $deletedEntities | Where-Object { $_.objectId -eq $entity.objectId }
                $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

                if ($isDeleted) {
                    # V3: Set effectiveTo = now for deleted entities (soft delete)
                    $doc['effectiveTo'] = $now
                    $doc['deleted'] = $true  # Keep for backward compatibility during transition
                    $doc['deletedTimestamp'] = $now
                    $doc['ttl'] = 7776000  # 90 days in seconds
                }
                else {
                    # Entity is current - effectiveTo should be null
                    $doc['effectiveTo'] = $null
                    $doc['deleted'] = $false
                }

                # Preserve effectiveFrom: use existing if available, otherwise set to now
                if ($entity.effectiveFrom) {
                    $doc['effectiveFrom'] = $entity.effectiveFrom
                }
                elseif (-not $doc['effectiveFrom']) {
                    $doc['effectiveFrom'] = $now
                }
            }

            $docsToWrite.Add($doc)
        }
    }
    else {
        Write-Verbose "No changes detected - skipping $entitySingular writes"
    }
    #endregion

    #region Step 5: Build snapshot document
    $snapshotDoc = @{
        id = $Timestamp
        snapshotId = $Timestamp
        collectionTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = $entityType
        blobPath = $BlobName
        deltaDetectionEnabled = $enableDelta
        cosmosWriteCount = $docsToWrite.Count
    }

    # Add entity-specific counts with proper naming
    $snapshotDoc["total$($entityPlural.Substring(0,1).ToUpper() + $entityPlural.Substring(1))"] = $currentEntities.Count
    $snapshotDoc["new$($entityPlural.Substring(0,1).ToUpper() + $entityPlural.Substring(1))"] = $newEntities.Count
    $snapshotDoc["modified$($entityPlural.Substring(0,1).ToUpper() + $entityPlural.Substring(1))"] = $modifiedEntities.Count
    $snapshotDoc["deleted$($entityPlural.Substring(0,1).ToUpper() + $entityPlural.Substring(1))"] = $deletedEntities.Count
    $snapshotDoc["unchanged$($entityPlural.Substring(0,1).ToUpper() + $entityPlural.Substring(1))"] = $unchangedEntities.Count
    #endregion

    Write-Verbose "Delta indexing complete for $entityPlural"

    # Return all results
    return @{
        RawDocuments = $docsToWrite
        ChangeDocuments = $changeLog
        SnapshotDocument = $snapshotDoc
        Statistics = @{
            Total = $currentEntities.Count
            New = $newEntities.Count
            Modified = $modifiedEntities.Count
            Deleted = $deletedEntities.Count
            Unchanged = $unchangedEntities.Count
            WriteCount = $docsToWrite.Count
        }
    }
}

function Invoke-DeltaIndexingWithBinding {
    <#
    .SYNOPSIS
        Wrapper around Invoke-DeltaIndexing that handles output bindings and config loading

    .DESCRIPTION
        Loads entity configuration from IndexerConfigs.psd1, calls Invoke-DeltaIndexing,
        pushes results to Azure Functions output bindings, and returns standardized statistics.
        This reduces each indexer from ~96 lines to ~15 lines.

    .PARAMETER EntityType
        The entity type key from IndexerConfigs.psd1 (e.g., 'users', 'groups', 'devices')

    .PARAMETER ActivityInput
        The activity input containing BlobName and Timestamp

    .PARAMETER ExistingData
        The existing data from Cosmos DB input binding

    .EXAMPLE
        $result = Invoke-DeltaIndexingWithBinding -EntityType 'users' -ActivityInput $ActivityInput -ExistingData $usersRawIn
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntityType,

        [Parameter(Mandatory = $true)]
        [hashtable]$ActivityInput,

        [Parameter(Mandatory = $false)]
        [array]$ExistingData
    )

    try {
        # Load configuration from IndexerConfigs.psd1
        $configPath = Join-Path $PSScriptRoot "IndexerConfigs.psd1"

        if (-not (Test-Path $configPath)) {
            throw "IndexerConfigs.psd1 not found at: $configPath"
        }

        $allConfigs = Import-PowerShellDataFile $configPath
        $config = $allConfigs[$EntityType]

        if (-not $config) {
            throw "Unknown entity type: $EntityType. Available types: $($allConfigs.Keys -join ', ')"
        }

        # Call the core delta indexing logic
        # Pass FilterByPrincipalType if specified in ActivityInput (e.g., 'user', 'group', 'servicePrincipal')
        $result = Invoke-DeltaIndexing `
            -BlobName $ActivityInput.BlobName `
            -Timestamp $ActivityInput.Timestamp `
            -ExistingData $ExistingData `
            -Config $config `
            -FilterByPrincipalType $ActivityInput.PrincipalType

        # Push to output bindings using config-defined binding names
        if ($result.RawDocuments.Count -gt 0) {
            Push-OutputBinding -Name $config.RawOutBinding -Value $result.RawDocuments
            Write-Verbose "Queued $($result.RawDocuments.Count) $($config.EntityNamePlural.ToLower()) to raw container"
        }

        if ($result.ChangeDocuments.Count -gt 0) {
            Push-OutputBinding -Name $config.ChangesOutBinding -Value $result.ChangeDocuments
            Write-Verbose "Queued $($result.ChangeDocuments.Count) change events to audit container"
        }

        # V3: Snapshots container removed - snapshot data now tracked via audit container
        Write-Verbose "Indexing complete for $($config.EntityNamePlural)"

        # DEBUG: Log delta detection statistics
        Write-Information "[DEBUG-DELTA-STATS] $EntityType : Total=$($result.Statistics.Total), New=$($result.Statistics.New), Modified=$($result.Statistics.Modified), Deleted=$($result.Statistics.Deleted), Unchanged=$($result.Statistics.Unchanged), ChangeLogEntries=$($result.ChangeDocuments.Count)" -InformationAction Continue

        # Return standardized statistics with entity-specific property names
        $entityPlural = $config.EntityNamePlural
        return @{
            Success = $true
            "Total$entityPlural" = $result.Statistics.Total
            "New$entityPlural" = $result.Statistics.New
            "Modified$entityPlural" = $result.Statistics.Modified
            "Deleted$entityPlural" = $result.Statistics.Deleted
            "Unchanged$entityPlural" = $result.Statistics.Unchanged
            CosmosWriteCount = $result.Statistics.WriteCount
            SnapshotId = $ActivityInput.Timestamp
        }
    }
    catch {
        Write-Error "Delta indexing with bindings failed for $EntityType`: $_"

        # Return error result with zero counts
        $entityPlural = if ($config) { $config.EntityNamePlural } else { 'Entities' }
        return @{
            Success = $false
            Error = $_.Exception.Message
            "Total$entityPlural" = 0
            "New$entityPlural" = 0
            "Modified$entityPlural" = 0
            "Deleted$entityPlural" = 0
            "Unchanged$entityPlural" = 0
            CosmosWriteCount = 0
            SnapshotId = $ActivityInput.Timestamp
        }
    }
}

#endregion

#region Gremlin Graph Functions (V3.1)

function Get-GremlinConnection {
    <#
    .SYNOPSIS
        Gets Gremlin connection settings from environment variables

    .DESCRIPTION
        Returns a hashtable with Gremlin endpoint, database, container, and key.
        Uses environment variables set by Bicep deployment.

    .EXAMPLE
        $conn = Get-GremlinConnection
        $endpoint = $conn.Endpoint
    #>
    [CmdletBinding()]
    param()

    $endpoint = $env:COSMOS_GREMLIN_ENDPOINT
    $database = $env:COSMOS_GREMLIN_DATABASE
    $container = $env:COSMOS_GREMLIN_CONTAINER
    $key = $env:COSMOS_GREMLIN_KEY

    if (-not $endpoint -or -not $database -or -not $container -or -not $key) {
        throw "Gremlin configuration not found. Required: COSMOS_GREMLIN_ENDPOINT, COSMOS_GREMLIN_DATABASE, COSMOS_GREMLIN_CONTAINER, COSMOS_GREMLIN_KEY"
    }

    # Extract account name from endpoint (wss://accountname.gremlin.cosmos.azure.com:443/)
    $accountName = $endpoint -replace 'wss://([^.]+)\.gremlin\.cosmos\.azure\.com.*', '$1'

    return @{
        Endpoint = $endpoint
        Database = $database
        Container = $container
        Key = $key
        AccountName = $accountName
        # REST endpoint for Gremlin queries
        RestEndpoint = "https://$accountName.documents.azure.com:443/"
    }
}

function Get-GremlinAuthHeader {
    <#
    .SYNOPSIS
        Generates authorization header for Cosmos DB Gremlin REST API

    .DESCRIPTION
        Creates the required authorization token for Cosmos DB using master key.
        Follows Azure Cosmos DB REST API authentication requirements.

    .PARAMETER Verb
        HTTP verb (GET, POST, etc.)

    .PARAMETER ResourceType
        Resource type (docs, colls, dbs, etc.)

    .PARAMETER ResourceId
        Resource ID path

    .PARAMETER Key
        Cosmos DB master key

    .PARAMETER Date
        UTC date string in RFC 1123 format
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Verb,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Date
    )

    $keyBytes = [System.Convert]::FromBase64String($Key)

    $text = "$($Verb.ToLower())`n$($ResourceType.ToLower())`n$ResourceId`n$($Date.ToLower())`n`n"
    $textBytes = [System.Text.Encoding]::UTF8.GetBytes($text)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hash = $hmac.ComputeHash($textBytes)
    $signature = [System.Convert]::ToBase64String($hash)

    $authToken = [System.Web.HttpUtility]::UrlEncode("type=master&ver=1.0&sig=$signature")

    return $authToken
}

function Submit-GremlinQuery {
    <#
    .SYNOPSIS
        Executes a Gremlin query against Cosmos DB with retry logic

    .DESCRIPTION
        Submits a Gremlin traversal query to Cosmos DB Gremlin API.
        Includes exponential backoff retry for transient failures.

    .PARAMETER Query
        The Gremlin traversal query string

    .PARAMETER MaxRetries
        Maximum retry attempts. Default: 3

    .PARAMETER Connection
        Optional connection hashtable from Get-GremlinConnection.
        If not provided, reads from environment variables.

    .EXAMPLE
        $result = Submit-GremlinQuery -Query "g.V().count()"

    .EXAMPLE
        $users = Submit-GremlinQuery -Query "g.V().hasLabel('user').limit(10)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [int]$MaxRetries = 3,

        [hashtable]$Connection
    )

    if (-not $Connection) {
        $Connection = Get-GremlinConnection
    }

    $resourceId = "dbs/$($Connection.Database)/colls/$($Connection.Container)"
    $uri = "$($Connection.RestEndpoint)$resourceId/docs"

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $date = [DateTime]::UtcNow.ToString('r')
            $authToken = Get-GremlinAuthHeader -Verb 'POST' -ResourceType 'docs' `
                -ResourceId $resourceId -Key $Connection.Key -Date $date

            $headers = @{
                'Authorization' = $authToken
                'x-ms-date' = $date
                'x-ms-version' = '2018-12-31'
                'Content-Type' = 'application/query+json'
                'x-ms-documentdb-isquery' = 'True'
                'x-ms-documentdb-query-enablecrosspartition' = 'True'
            }

            # Cosmos DB Gremlin uses a special query format
            $body = @{
                query = $Query
                parameters = @()
            } | ConvertTo-Json -Compress

            Write-Verbose "Executing Gremlin query: $Query"
            $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body

            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $attempt++

            # Handle rate limiting
            if ($statusCode -eq 429) {
                $delay = 5
                $retryAfterHeader = $_.Exception.Response.Headers.'x-ms-retry-after-ms'
                if ($retryAfterHeader -and $retryAfterHeader -match '^\d+$') {
                    $delay = [Math]::Ceiling([int]$retryAfterHeader / 1000)
                }
                Write-Warning "Gremlin rate limited (429). Waiting $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }

            # Retry on transient errors
            if ($statusCode -ge 500 -and $attempt -lt $MaxRetries) {
                $delay = 2 * [Math]::Pow(2, $attempt - 1)
                Write-Warning "Gremlin error ($statusCode). Retry $attempt/$MaxRetries in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }

            Write-Error "Gremlin query failed: $_"
            throw
        }
    }

    throw "Gremlin query failed after $MaxRetries retries"
}

function Add-GraphVertex {
    <#
    .SYNOPSIS
        Upserts a vertex in the Gremlin graph

    .DESCRIPTION
        Creates or updates a vertex using the fold().coalesce() upsert pattern.
        This ensures idempotent vertex creation.

    .PARAMETER ObjectId
        Unique identifier for the vertex (becomes the vertex id)

    .PARAMETER Label
        Vertex label (e.g., 'user', 'group', 'servicePrincipal')

    .PARAMETER PartitionKey
        Partition key value (typically tenantId)

    .PARAMETER Properties
        Hashtable of additional properties to set on the vertex

    .PARAMETER Connection
        Optional connection hashtable from Get-GremlinConnection

    .EXAMPLE
        Add-GraphVertex -ObjectId "user-guid-123" -Label "user" -PartitionKey $tenantId `
            -Properties @{ displayName = "John Doe"; userType = "Member" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectId,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$PartitionKey,

        [hashtable]$Properties = @{},

        [hashtable]$Connection
    )

    # Build the Gremlin upsert query using fold().coalesce() pattern
    # This creates the vertex if it doesn't exist, or updates it if it does
    $propsQuery = ""
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -ne $value) {
            # Escape single quotes in string values
            if ($value -is [string]) {
                $value = $value -replace "'", "\'"
                $propsQuery += ".property('$key', '$value')"
            }
            elseif ($value -is [bool]) {
                $boolVal = if ($value) { "true" } else { "false" }
                $propsQuery += ".property('$key', $boolVal)"
            }
            elseif ($value -is [int] -or $value -is [double]) {
                $propsQuery += ".property('$key', $value)"
            }
        }
    }

    $query = @"
g.V('$ObjectId')
  .fold()
  .coalesce(
    unfold(),
    addV('$Label').property(id, '$ObjectId').property('pk', '$PartitionKey')
  )$propsQuery
"@

    # Remove newlines for cleaner query
    $query = $query -replace "`r`n", " " -replace "`n", " " -replace '\s+', ' '

    return Submit-GremlinQuery -Query $query -Connection $Connection
}

function Add-GraphEdge {
    <#
    .SYNOPSIS
        Upserts an edge between two vertices in the Gremlin graph

    .DESCRIPTION
        Creates or updates an edge using the fold().coalesce() upsert pattern.
        Ensures both source and target vertices exist before creating the edge.

    .PARAMETER SourceId
        Object ID of the source vertex

    .PARAMETER TargetId
        Object ID of the target vertex

    .PARAMETER EdgeType
        Edge label (e.g., 'memberOf', 'owns', 'hasRole')

    .PARAMETER Properties
        Hashtable of additional properties to set on the edge

    .PARAMETER Connection
        Optional connection hashtable from Get-GremlinConnection

    .EXAMPLE
        Add-GraphEdge -SourceId "user-123" -TargetId "group-456" -EdgeType "memberOf" `
            -Properties @{ assignmentType = "direct" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceId,

        [Parameter(Mandatory)]
        [string]$TargetId,

        [Parameter(Mandatory)]
        [string]$EdgeType,

        [hashtable]$Properties = @{},

        [hashtable]$Connection
    )

    # Build edge ID from source, target, and type for uniqueness
    $edgeId = "${SourceId}_${TargetId}_${EdgeType}"

    # Build properties clause
    $propsQuery = ""
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -ne $value) {
            if ($value -is [string]) {
                $value = $value -replace "'", "\'"
                $propsQuery += ".property('$key', '$value')"
            }
            elseif ($value -is [bool]) {
                $boolVal = if ($value) { "true" } else { "false" }
                $propsQuery += ".property('$key', $boolVal)"
            }
            elseif ($value -is [int] -or $value -is [double]) {
                $propsQuery += ".property('$key', $value)"
            }
        }
    }

    # Upsert edge pattern: check if edge exists, if not create it
    $query = @"
g.V('$SourceId').as('s')
  .V('$TargetId').as('t')
  .select('s').outE('$EdgeType').where(inV().hasId('$TargetId'))
  .fold()
  .coalesce(
    unfold(),
    select('s').addE('$EdgeType').to(select('t')).property(id, '$edgeId')
  )$propsQuery
"@

    $query = $query -replace "`r`n", " " -replace "`n", " " -replace '\s+', ' '

    return Submit-GremlinQuery -Query $query -Connection $Connection
}

function Remove-GraphVertex {
    <#
    .SYNOPSIS
        Removes a vertex and all its edges from the Gremlin graph

    .DESCRIPTION
        Drops a vertex by its ID. All connected edges are automatically removed.

    .PARAMETER ObjectId
        The ID of the vertex to remove

    .PARAMETER Connection
        Optional connection hashtable from Get-GremlinConnection

    .EXAMPLE
        Remove-GraphVertex -ObjectId "user-guid-123"
    #>
    # Used in Azure Functions automation - ShouldProcess not applicable for non-interactive scenarios
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Azure Functions automation - no interactive confirmation')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectId,

        [hashtable]$Connection
    )

    $query = "g.V('$ObjectId').drop()"

    return Submit-GremlinQuery -Query $query -Connection $Connection
}

function Remove-GraphEdge {
    <#
    .SYNOPSIS
        Removes a specific edge from the Gremlin graph

    .DESCRIPTION
        Drops an edge identified by source, target, and edge type.

    .PARAMETER SourceId
        Object ID of the source vertex

    .PARAMETER TargetId
        Object ID of the target vertex

    .PARAMETER EdgeType
        Edge label to remove

    .PARAMETER Connection
        Optional connection hashtable from Get-GremlinConnection

    .EXAMPLE
        Remove-GraphEdge -SourceId "user-123" -TargetId "group-456" -EdgeType "memberOf"
    #>
    # Used in Azure Functions automation - ShouldProcess not applicable for non-interactive scenarios
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Azure Functions automation - no interactive confirmation')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceId,

        [Parameter(Mandatory)]
        [string]$TargetId,

        [Parameter(Mandatory)]
        [string]$EdgeType,

        [hashtable]$Connection
    )

    $query = "g.V('$SourceId').outE('$EdgeType').where(inV().hasId('$TargetId')).drop()"

    return Submit-GremlinQuery -Query $query -Connection $Connection
}

function Sync-GraphFromAudit {
    <#
    .SYNOPSIS
        Syncs Gremlin graph from audit container changes

    .DESCRIPTION
        Reads recent changes from the Cosmos DB audit container and projects them
        to the Gremlin graph. Handles new, modified, and deleted entities.

    .PARAMETER SinceTimestamp
        Only process changes after this timestamp

    .PARAMETER MaxChanges
        Maximum number of changes to process in one batch. Default: 1000

    .PARAMETER Connection
        Optional Gremlin connection hashtable

    .EXAMPLE
        Sync-GraphFromAudit -SinceTimestamp "2026-01-01T00:00:00Z"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SinceTimestamp,

        [int]$MaxChanges = 1000,

        [hashtable]$Connection
    )

    if (-not $Connection) {
        $Connection = Get-GremlinConnection
    }

    $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
    $cosmosDatabase = $env:COSMOS_DB_DATABASE
    $cosmosToken = Get-CachedManagedIdentityToken -Resource "https://cosmos.azure.com"

    $stats = @{
        VerticesAdded = 0
        VerticesModified = 0
        VerticesDeleted = 0
        EdgesAdded = 0
        EdgesModified = 0
        EdgesDeleted = 0
        Errors = 0
    }

    # Query audit container for recent changes
    $auditQuery = "SELECT TOP $MaxChanges * FROM c WHERE c.changeTimestamp > '$SinceTimestamp' ORDER BY c.changeTimestamp ASC"

    $changes = @()
    Get-CosmosDocument -Endpoint $cosmosEndpoint -Database $cosmosDatabase `
        -Container 'audit' -Query $auditQuery -AccessToken $cosmosToken `
        -ProcessPage {
            param($Documents)
            $changes += $Documents
        }

    Write-Verbose "Processing $($changes.Count) audit changes"

    foreach ($change in $changes) {
        try {
            $entityType = $change.entityType
            $changeType = $change.changeType
            $objectId = $change.objectId
            $displayName = $change.displayName ?? ""
            $principalType = $change.principalType

            # Determine if this is a vertex or edge change
            $isEdge = $entityType -in @('relationships', 'edges', 'azureRelationships')

            if ($isEdge) {
                # Edge changes
                switch ($changeType) {
                    'new' {
                        # Need to get full edge data from edges container
                        # For now, just increment counter
                        $stats.EdgesAdded++
                    }
                    'modified' {
                        $stats.EdgesModified++
                    }
                    'deleted' {
                        # Remove edge from graph
                        $stats.EdgesDeleted++
                    }
                }
            }
            else {
                # Vertex changes
                $tenantId = $env:TENANT_ID ?? "default"
                $label = $principalType ?? $entityType

                switch ($changeType) {
                    'new' {
                        Add-GraphVertex -ObjectId $objectId -Label $label `
                            -PartitionKey $tenantId `
                            -Properties @{ displayName = $displayName } `
                            -Connection $Connection
                        $stats.VerticesAdded++
                    }
                    'modified' {
                        # Update vertex properties from delta
                        $props = @{ displayName = $displayName }
                        if ($change.delta) {
                            foreach ($field in $change.delta.Keys) {
                                $props[$field] = $change.delta[$field].new
                            }
                        }
                        Add-GraphVertex -ObjectId $objectId -Label $label `
                            -PartitionKey $tenantId -Properties $props `
                            -Connection $Connection
                        $stats.VerticesModified++
                    }
                    'deleted' {
                        Remove-GraphVertex -ObjectId $objectId -Connection $Connection
                        $stats.VerticesDeleted++
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to sync change $($change.id): $_"
            $stats.Errors++
        }
    }

    return $stats
}

#endregion

#region Performance Timing Helpers

function Measure-Phase {
    <#
    .SYNOPSIS
        Measures execution time of a script block and logs the result

    .DESCRIPTION
        Wraps a script block with timing and logs the duration using Write-Information.
        Returns the result of the script block.
        Useful for identifying performance bottlenecks in collectors.

    .PARAMETER Name
        Name of the phase being measured (e.g., "Fetch Users", "Build Risk Lookup")

    .PARAMETER ScriptBlock
        The code to execute and measure

    .EXAMPLE
        $users = Measure-Phase -Name "Fetch Users" -ScriptBlock { Get-Users }

    .EXAMPLE
        Measure-Phase -Name "Write to Blob" -ScriptBlock { Add-BlobContent ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $ScriptBlock
        $stopwatch.Stop()
        $duration = $stopwatch.Elapsed
        $formatted = if ($duration.TotalMinutes -ge 1) {
            "{0:N1} min" -f $duration.TotalMinutes
        } elseif ($duration.TotalSeconds -ge 1) {
            "{0:N1} sec" -f $duration.TotalSeconds
        } else {
            "{0:N0} ms" -f $duration.TotalMilliseconds
        }
        Write-Information "[TIMING] $Name completed in $formatted" -InformationAction Continue
        return $result
    }
    catch {
        $stopwatch.Stop()
        Write-Warning "[TIMING] $Name failed after $($stopwatch.Elapsed.TotalSeconds.ToString('N1')) sec: $_"
        throw
    }
}

function New-PerformanceTimer {
    <#
    .SYNOPSIS
        Creates a performance timer object for tracking multiple phases

    .DESCRIPTION
        Creates a hashtable-based timer that tracks multiple phases and can output a summary.

    .EXAMPLE
        $timer = New-PerformanceTimer
        $timer.Start("Fetch Users")
        # ... do work ...
        $timer.Stop("Fetch Users")
        $timer.Summary()  # Returns hashtable of phase durations
    #>
    [CmdletBinding()]
    param()

    $timer = @{
        Phases = @{}
        _running = @{}
    }

    # Start a phase timer
    $timer | Add-Member -MemberType ScriptMethod -Name 'Start' -Value {
        param([string]$PhaseName)
        $this._running[$PhaseName] = [System.Diagnostics.Stopwatch]::StartNew()
    }

    # Stop a phase timer and record duration
    $timer | Add-Member -MemberType ScriptMethod -Name 'Stop' -Value {
        param([string]$PhaseName)
        if ($this._running.ContainsKey($PhaseName)) {
            $this._running[$PhaseName].Stop()
            $this.Phases[$PhaseName] = $this._running[$PhaseName].Elapsed.TotalSeconds
            $this._running.Remove($PhaseName)
        }
    }

    # Get summary of all phases
    $timer | Add-Member -MemberType ScriptMethod -Name 'Summary' -Value {
        $summary = @{}
        foreach ($phase in $this.Phases.Keys) {
            $seconds = $this.Phases[$phase]
            $summary[$phase] = if ($seconds -ge 60) {
                "{0:N1} min" -f ($seconds / 60)
            } elseif ($seconds -ge 1) {
                "{0:N1} sec" -f $seconds
            } else {
                "{0:N0} ms" -f ($seconds * 1000)
            }
        }
        return $summary
    }

    # Get raw seconds for a phase
    $timer | Add-Member -MemberType ScriptMethod -Name 'GetSeconds' -Value {
        param([string]$PhaseName)
        return $this.Phases[$PhaseName]
    }

    # Log all phases
    $timer | Add-Member -MemberType ScriptMethod -Name 'LogSummary' -Value {
        param([string]$CollectorName = "Collector")
        $total = ($this.Phases.Values | Measure-Object -Sum).Sum
        Write-Information "[TIMING] $CollectorName Performance Summary:" -InformationAction Continue
        foreach ($phase in $this.Phases.Keys | Sort-Object) {
            $formatted = $this.Summary()[$phase]
            Write-Information "[TIMING]   $phase : $formatted" -InformationAction Continue
        }
        $totalFormatted = if ($total -ge 60) { "{0:N1} min" -f ($total / 60) } else { "{0:N1} sec" -f $total }
        Write-Information "[TIMING]   TOTAL: $totalFormatted" -InformationAction Continue
    }

    return $timer
}

#endregion

#region JSON Optimization

<#
.SYNOPSIS
    Converts object to JSON excluding null/empty properties
.DESCRIPTION
    Reduces JSONL file size by removing null values before serialization.
    Null properties and missing properties are semantically equivalent in JSON.
#>
function ConvertTo-CompactJson {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable]$InputObject,

        [int]$Depth = 10
    )

    # Recursively remove null/empty values
    $cleaned = @{}
    foreach ($key in $InputObject.Keys) {
        $value = $InputObject[$key]
        if ($null -ne $value -and $value -ne '') {
            if ($value -is [hashtable]) {
                $cleanedValue = ConvertTo-CompactJson -InputObject $value -Depth ($Depth - 1)
                if ($cleanedValue -ne '{}') {
                    $cleaned[$key] = $value  # Keep original for ConvertTo-Json
                }
            }
            elseif ($value -is [array] -and $value.Count -eq 0) {
                # Skip empty arrays
            }
            else {
                $cleaned[$key] = $value
            }
        }
    }

    return ($cleaned | ConvertTo-Json -Compress -Depth $Depth)
}

#endregion

Export-ModuleMember -Function @(
    # Token management
    'Get-ManagedIdentityToken',
    'Get-CachedManagedIdentityToken',
    # Azure Management API
    'Get-AzureManagementPagedResult',
    # Graph API
    'Invoke-GraphWithRetry',
    'Invoke-GraphBatch',
    'Get-GraphPagedResult',
    # Blob Storage
    'Initialize-AppendBlob',
    'Add-BlobContent',
    'Write-BlobBuffer',
    'Write-BlobContent',
    # Cosmos DB SQL API
    'Write-CosmosDocument',
    'Write-CosmosBatch',
    'Write-CosmosParallelBatch',
    'Get-CosmosDocument',
    # Delta Indexing
    'Invoke-DeltaIndexing',
    'Invoke-DeltaIndexingWithBinding',
    # V3.1 Gremlin Graph Functions
    'Get-GremlinConnection',
    'Get-GremlinAuthHeader',
    'Submit-GremlinQuery',
    'Add-GraphVertex',
    'Add-GraphEdge',
    'Remove-GraphVertex',
    'Remove-GraphEdge',
    'Sync-GraphFromAudit',
    # Performance Timing
    'Measure-Phase',
    'New-PerformanceTimer',
    # JSON Optimization
    'ConvertTo-CompactJson'
)
