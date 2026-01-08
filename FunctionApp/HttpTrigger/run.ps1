#region HTTP Trigger Function
<#
This HTTP-triggered function manually starts the Entra data collection orchestrator.
It's the entry point for manually triggering the Entra data collection workflow.
#>
#endregion

using namespace System.Net

# Azure Functions runtime passes these parameters - not all are used
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TriggerMetadata', Justification = 'Required by Azure Functions runtime')]
param($Request, $TriggerMetadata)

#region Function Logic
try {
    Write-Verbose "HTTP trigger received - starting orchestrator"
    
    $InstanceId = Start-DurableOrchestration -FunctionName 'Orchestrator'
    Write-Verbose "Started orchestration with instance ID: $InstanceId"
    
    $Response = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $InstanceId
    
    Write-Verbose "Returning status URLs to client"
    Push-OutputBinding -Name Response -Value $Response
    
} catch {
    Write-Error "Failed to start orchestration: $_"
    
    $ErrorResponse = @{
        statusCode = [HttpStatusCode]::InternalServerError
        body = @{
            error = $_.Exception.Message
        } | ConvertTo-Json
    }
    
    Push-OutputBinding -Name Response -Value $ErrorResponse
}
#endregion
