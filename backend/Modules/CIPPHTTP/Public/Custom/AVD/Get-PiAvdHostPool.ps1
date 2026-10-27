function Get-PiAvdHostPool {
    <#
    .SYNOPSIS
        Lists AVD host pools for a set of CIPP tenants via Azure Resource Graph.
    .DESCRIPTION
        Fork addition (Prometheus Informatik).
        Lighthouse mode: one query from the partner tenant, filtered to the given tenants
        in PowerShell (no request input reaches the KQL).
        Tenant mode: one query per customer tenant with that tenant's token; tenants
        without RBAC are skipped and reported in the warnings collection.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tenants,

        # Receives per-tenant failures (Tenant mode) so callers can surface them.
        [System.Collections.Generic.List[object]]$Warnings
    )

    $Query = @'
resources
| where type =~ 'microsoft.desktopvirtualization/hostpools'
| project id, name, tenantId, subscriptionId, resourceGroup, location,
    friendlyName = tostring(properties.friendlyName),
    hostPoolType = tostring(properties.hostPoolType),
    loadBalancerType = tostring(properties.loadBalancerType),
    maxSessionLimit = toint(properties.maxSessionLimit),
    personalDesktopAssignmentType = tostring(properties.personalDesktopAssignmentType),
    preferredAppGroupType = tostring(properties.preferredAppGroupType),
    startVMOnConnect = tobool(properties.startVMOnConnect),
    validationEnvironment = tobool(properties.validationEnvironment),
    publicNetworkAccess = tostring(properties.publicNetworkAccess)
'@

    $ByTenantId = @{}
    foreach ($Tenant in $Tenants) { $ByTenantId[[string]$Tenant.customerId] = $Tenant }

    $Rows = if ((Get-PiAvdAuthMode) -eq 'Lighthouse') {
        Search-PiResourceGraph -Query $Query -TenantId $env:TenantID
    } else {
        foreach ($Tenant in $Tenants) {
            try {
                Search-PiResourceGraph -Query $Query -TenantId $Tenant.customerId
            } catch {
                if ($null -ne $Warnings) {
                    $Warnings.Add([pscustomobject]@{ Tenant = $Tenant.defaultDomainName; Error = $_.Exception.Message })
                }
            }
        }
    }

    foreach ($Row in @($Rows)) {
        $Tenant = $ByTenantId[[string]$Row.tenantId]
        if (-not $Tenant) { continue } # delegated but not in scope for this user / not in CIPP
        $Row | Add-Member -NotePropertyName 'Tenant' -NotePropertyValue $Tenant.defaultDomainName -Force
        $Row | Add-Member -NotePropertyName 'TenantName' -NotePropertyValue $Tenant.displayName -Force
        $Row
    }
}
