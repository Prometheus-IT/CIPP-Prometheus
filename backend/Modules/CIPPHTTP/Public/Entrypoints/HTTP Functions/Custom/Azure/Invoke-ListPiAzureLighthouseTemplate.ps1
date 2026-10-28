function Invoke-ListPiAzureLighthouseTemplate {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.Read
    .DESCRIPTION
        Fork addition. Read-only. Returns the Azure Lighthouse onboarding template for the AVD module with this CIPP instance's partner tenant id and delegated principal filled in, plus the matching deployment commands. Deploying it is done by a customer administrator; CIPP never deploys it.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    try {
        $Mode = Get-PiAvdAuthMode
        $Principal = Get-PiLighthousePrincipal
        $Template = Get-PiLighthouseTemplate -ManagedByTenantId $env:TenantID -PrincipalId $Principal.PrincipalId
        $FileName = 'cipp-avd-lighthouse.json'

        $Body = [ordered]@{
            AuthMode          = $Mode
            ManagedByTenantId = [string]$env:TenantID
            PrincipalId       = $Principal.PrincipalId
            PrincipalName     = $Principal.DisplayName
            PrincipalSource   = $Principal.Source
            Roles             = @(Get-PiLighthouseRoles)
            FileName          = $FileName
            AzCli             = "az deployment sub create --name cipp-avd-lighthouse --location switzerlandnorth --template-file $FileName"
            AzPowerShell      = "New-AzSubscriptionDeployment -Name cipp-avd-lighthouse -Location switzerlandnorth -TemplateFile .\$FileName"
            PortalUrl         = 'https://portal.azure.com/#create/Microsoft.Template'
            # Serialized here so the host's JSON depth limit cannot truncate nested template objects.
            TemplateJson      = ($Template | ConvertTo-Json -Depth 20)
            Note              = if ($Mode -eq 'Lighthouse') {
                'Deploy once per customer subscription that holds AVD resources, signed in to the customer tenant with Owner on that subscription.'
            } else {
                'PiAvdArmAuthMode is Tenant: CIPP does not use Lighthouse for this instance. Assign the same roles to the SAM service principal inside each customer tenant instead.'
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -message "Failed to build the Lighthouse onboarding template: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to build the Lighthouse onboarding template: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
