function Search-PiAzureReportGraph {
    <#
    .SYNOPSIS
        Reads a complete Resource Graph result for the Azure reports, failing closed on truncation.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Query,
        [Parameter(Mandatory)] [string]$TenantId,
        [string[]]$Subscriptions
    )

    $Rows = [System.Collections.Generic.List[object]]::new()
    $Tokens = [System.Collections.Generic.HashSet[string]]::new()
    $SkipToken = $null
    do {
        $Options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
        if ($SkipToken) { $Options['$skipToken'] = $SkipToken }
        $Body = @{ query = $Query; options = $Options }
        if ($Subscriptions) { $Body.subscriptions = @($Subscriptions) }
        $Response = Send-PiArmRequest -TenantId $TenantId -Method POST -Body $Body -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
        if ($null -eq $Response -or $null -eq $Response.data) { throw 'Resource Graph returned no data envelope.' }
        foreach ($Row in @($Response.data)) {
            if ($null -ne $Row) { $Rows.Add($Row) }
        }
        $SkipToken = [string]$Response.'$skipToken'
        if ($SkipToken) {
            if (-not $Tokens.Add($SkipToken) -or $Tokens.Count -ge 100) { throw 'Resource Graph pagination did not complete.' }
        } elseif ([string]$Response.resultTruncated -eq 'true') {
            throw 'Resource Graph truncated the result without a continuation token.'
        }
    } while ($SkipToken)
    return $Rows.ToArray()
}
