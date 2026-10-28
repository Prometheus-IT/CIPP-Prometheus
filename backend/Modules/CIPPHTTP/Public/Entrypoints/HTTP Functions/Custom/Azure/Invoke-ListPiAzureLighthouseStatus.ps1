function Invoke-ListPiAzureLighthouseStatus {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.Read
    .DESCRIPTION
        Fork addition. Read-only. Shows per tenant (or AllTenants) which Azure subscriptions the CIPP SAM app can reach through Azure Lighthouse or direct RBAC, which AVD module roles it holds there, and how many AVD host pools each subscription contains.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain, customerId or AllTenants.
    $TenantFilter = $Request.Query.tenantFilter

    try {
        $Tenants = Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter
        $Principal = if ((Get-PiAvdAuthMode) -eq 'Lighthouse') { Get-PiLighthousePrincipal } else { $null }
        $Results = @(Get-PiAzureAccessStatus -Tenants $Tenants -Principal $Principal | Sort-Object -Property Tenant)

        foreach ($Row in $Results | Where-Object Status -EQ 'Unknown') {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Row.Tenant -message "Azure access status unknown: $($Row.Detail)" -Sev 'Warning'
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Results
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to read Azure Lighthouse status: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to read Azure Lighthouse status: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
