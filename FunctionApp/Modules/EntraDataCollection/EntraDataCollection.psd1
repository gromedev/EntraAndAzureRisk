@{
    RootModule = 'EntraDataCollection.psm1'
    ModuleVersion = '1.3.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Entra Risk Analysis Team'
    CompanyName = 'Unknown'
    Copyright = '(c) 2024. All rights reserved.'
    Description = 'PowerShell module for Microsoft Entra ID data collection and Cosmos DB operations'
    
    PowerShellVersion = '7.4'
    
    FunctionsToExport = @(
        'Get-ManagedIdentityToken',
        'Get-CachedManagedIdentityToken',
        'Get-AzureManagementPagedResult',
        'Get-GraphPagedResult',
        'Invoke-GraphWithRetry',
        'Initialize-AppendBlob',
        'Add-BlobContent',
        'Write-BlobBuffer',
        'Write-CosmosDocument',
        'Write-CosmosBatch',
        'Write-CosmosParallelBatch',
        'Get-CosmosDocument',
        'Invoke-DeltaIndexing',
        'Invoke-DeltaIndexingWithBinding'
    )
    
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
    
    PrivateData = @{
        PSData = @{
            Tags = @('Entra', 'Azure', 'AD', 'Identity', 'Security', 'Cosmos', 'DataCollection')
            LicenseUri = ''
            ProjectUri = ''
            IconUri = ''
            ReleaseNotes = 'v1.3.0: Renamed functions to use singular nouns per PSScriptAnalyzer, added Write-BlobBuffer'
        }
    }
}
