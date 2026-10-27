function Get-PiAvdVmPowerState {
    <#
    .SYNOPSIS
        Returns a hashtable of lower-cased VM resource id -> power state display text.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). One Resource Graph query instead of one
        instanceView call per session host. Failures return an empty table: power state
        is a nice-to-have column, never a reason to fail the session host list.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tenants
    )

    $PowerStates = @{}

    # Tenant ids come from CIPP's own tenant cache, but validate them anyway before
    # they are placed in KQL.
    $TenantIds = @(
        foreach ($Tenant in $Tenants) {
            $Parsed = [guid]::Empty
            if ([guid]::TryParse([string]$Tenant.customerId, [ref]$Parsed)) { $Parsed.ToString() }
        }
    )
    if ($TenantIds.Count -eq 0) { return $PowerStates }

    $BuildQuery = {
        param([string[]]$Ids)
        $InList = ($Ids | ForEach-Object { "'$_'" }) -join ','
        @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| where tenantId in~ ($InList)
| project id = tolower(id), powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
"@
    }

    try {
        $Rows = if ((Get-PiAvdAuthMode) -eq 'Lighthouse') {
            Search-PiResourceGraph -Query (& $BuildQuery $TenantIds) -TenantId $env:TenantID
        } else {
            foreach ($Id in $TenantIds) {
                try { Search-PiResourceGraph -Query (& $BuildQuery @($Id)) -TenantId $Id } catch { }
            }
        }
        foreach ($Row in @($Rows)) {
            if ($Row.id) { $PowerStates[[string]$Row.id] = $Row.powerState }
        }
    } catch {
        Write-Information "Get-PiAvdVmPowerState: $($_.Exception.Message)"
    }

    return $PowerStates
}
