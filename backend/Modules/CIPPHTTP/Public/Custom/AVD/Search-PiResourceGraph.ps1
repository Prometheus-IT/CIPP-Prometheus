function Search-PiResourceGraph {
    <#
    .SYNOPSIS
        Runs an Azure Resource Graph query and pages through all results.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). With no subscription list, ARG queries every
        subscription the token can see. In Lighthouse mode that is every delegated customer
        subscription, and each row carries the customer's tenantId.

        Never interpolate request input into -Query. Filter on the PowerShell side, or
        validate the value (e.g. as a GUID) first.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [int]$PageSize = 1000
    )

    $Uri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
    $Rows = [System.Collections.Generic.List[object]]::new()
    $SkipToken = $null

    do {
        $Options = @{ resultFormat = 'objectArray'; '$top' = $PageSize }
        if ($SkipToken) { $Options['$skipToken'] = $SkipToken }
        $Body = @{ query = $Query; options = $Options }

        $Response = Send-PiArmRequest -Uri $Uri -Method 'POST' -Body $Body -TenantId $TenantId
        foreach ($Row in @($Response.data)) {
            if ($null -ne $Row) { $Rows.Add($Row) }
        }
        $SkipToken = $Response.'$skipToken'
    } while (-not [string]::IsNullOrWhiteSpace($SkipToken))

    return $Rows.ToArray()
}
