function Search-PiAvdStandardResourceGraph {
    <#
    .SYNOPSIS
        Pages through an Azure Resource Graph query for the AVD standards.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Never pass request or template input into
        -Query unvalidated.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [string]$TokenTenant
    )

    $Uri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
    $Rows = [System.Collections.Generic.List[object]]::new()
    $SkipToken = $null
    do {
        $Options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
        if ($SkipToken) { $Options['$skipToken'] = $SkipToken }
        $Response = Send-PiAvdStandardArmRequest -Uri $Uri -Method 'POST' -Body @{ query = $Query; options = $Options } -TokenTenant $TokenTenant
        foreach ($Row in @($Response.data)) { if ($null -ne $Row) { $Rows.Add($Row) } }
        $SkipToken = $Response.'$skipToken'
    } while (-not [string]::IsNullOrWhiteSpace($SkipToken))
    return $Rows.ToArray()
}
