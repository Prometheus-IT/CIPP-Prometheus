function Resolve-PiAvdTenantScope {
    <#
    .SYNOPSIS
        Turns a tenantFilter (domain, customerId or AllTenants) into the CIPP tenant objects
        the calling user may see.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Lighthouse tokens see every delegated
        subscription, including customers that are not in CIPP or that this CIPP user is
        scoped away from. Every AVD read and write is therefore filtered through this list.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Request,

        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)

    $Tenants = if ($TenantFilter -eq 'AllTenants') {
        @(Get-Tenants)
    } else {
        @(Get-Tenants -TenantFilter $TenantFilter)
    }

    if ($AllowedTenants -notcontains 'AllTenants') {
        $Tenants = @($Tenants | Where-Object { $AllowedTenants -contains $_.customerId })
    }

    if ($Tenants.Count -eq 0) {
        throw "Tenant '$TenantFilter' was not found or you do not have access to it."
    }

    return $Tenants
}
