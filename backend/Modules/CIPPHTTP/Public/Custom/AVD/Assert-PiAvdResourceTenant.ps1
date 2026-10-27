function Assert-PiAvdResourceTenant {
    <#
    .SYNOPSIS
        Throws unless an ARM resource id lives in a subscription owned by the given tenant.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Write endpoints take a full resource id from
        the request body. In Lighthouse mode the partner token can reach every delegated
        customer, so without this check a user scoped to tenant A could act on tenant B by
        posting B's resource id with tenantFilter=A.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId
    )

    if ($ResourceId -notmatch '^/subscriptions/(?<sub>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/') {
        throw 'Invalid resource id.'
    }
    # Validated GUID, safe to place in KQL.
    $SubscriptionId = $Matches['sub'].ToLowerInvariant()

    $Query = @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| where subscriptionId =~ '$SubscriptionId'
| project tenantId
"@
    $SearchTenant = if ((Get-PiAvdAuthMode) -eq 'Lighthouse') { $env:TenantID } else { $TenantId }
    $Owner = @(Search-PiResourceGraph -Query $Query -TenantId $SearchTenant) | Select-Object -First 1

    if (-not $Owner -or ([string]$Owner.tenantId -ne [string]$TenantId)) {
        throw 'The resource does not belong to the selected tenant, or its subscription is not delegated to CIPP.'
    }
}
