function Get-PiArmToken {
    <#
    .SYNOPSIS
        Returns an Authorization header for Azure Resource Manager.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Two auth modes, chosen with the
        PiAvdArmAuthMode environment variable:

          Lighthouse (default)  App-only token for the CIPP SAM app in the PARTNER tenant
                                ($env:TenantID). Customer subscriptions must be delegated to
                                the SAM app's service principal (or a group containing it)
                                through Azure Lighthouse. One token sees every delegated
                                subscription, so cross-tenant Resource Graph queries are cheap.

          Tenant                App-only token for the CIPP SAM app in the CUSTOMER tenant.
                                The SAM app's service principal in that tenant needs an Azure
                                RBAC role on the subscriptions that hold AVD resources.

        GDAP alone grants no Azure RBAC, so one of the two must be set up per customer.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        # Customer tenant id. Ignored in Lighthouse mode.
        [string]$TenantId
    )

    $Mode = Get-PiAvdAuthMode
    $TokenTenant = if ($Mode -eq 'Tenant') { $TenantId } else { $env:TenantID }
    if ([string]::IsNullOrWhiteSpace($TokenTenant)) {
        throw 'Get-PiArmToken: no tenant id available to request an ARM token for.'
    }

    # Get-GraphToken caches per tenant+scope and handles certificate-only SAM auth.
    return Get-GraphToken -tenantid $TokenTenant -scope 'https://management.azure.com/.default' -AsApp $true
}
