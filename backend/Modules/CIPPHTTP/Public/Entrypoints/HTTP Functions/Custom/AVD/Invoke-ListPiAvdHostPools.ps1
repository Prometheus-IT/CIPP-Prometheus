function Invoke-ListPiAvdHostPools {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.Read
    .DESCRIPTION
        Fork addition. Lists Azure Virtual Desktop host pools for a tenant (or AllTenants) using Azure Resource Graph through Azure Lighthouse or per-tenant RBAC.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain, customerId or AllTenants.
    $TenantFilter = $Request.Query.tenantFilter

    try {
        $Tenants = Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter
        $Warnings = [System.Collections.Generic.List[object]]::new()
        $Results = @(Get-PiAvdHostPool -Tenants $Tenants -Warnings $Warnings | Sort-Object -Property Tenant, name)

        foreach ($Warning in $Warnings) {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Warning.Tenant -message "AVD host pool query failed: $($Warning.Error)" -Sev 'Warning'
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Results
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to list AVD host pools: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to list AVD host pools: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
