function Write-PiAvdStandardResult {
    <#
    .SYNOPSIS
        Records the outcome of a Prometheus AVD standard for the report, drift view and alerts.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). One place for the report/alert handling every
        AVD standard shares, so they all treat "Azure access not delegated" the same way:
        reported as non-compliant with a pointer to the Lighthouse onboarding page.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant,

        [Parameter(Mandatory = $true)]
        [string]$StandardName,

        [Parameter(Mandatory = $true)]
        $Settings,

        [Parameter(Mandatory = $true)]
        [hashtable]$CurrentValue,

        [Parameter(Mandatory = $true)]
        [hashtable]$ExpectedValue,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Findings,

        $Object
    )

    $Findings = @($Findings | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($Settings.report -eq $true -or $Settings.remediate -eq $true) {
        Set-CIPPStandardsCompareField -FieldName "standards.$StandardName" -TenantFilter $Tenant -CurrentValue $CurrentValue -ExpectedValue $ExpectedValue
    }

    if ($Settings.alert -eq $true -and $Findings.Count -gt 0) {
        Write-StandardsAlert -message ($Findings -join ' ') -object ($Object ?? $CurrentValue) -tenant $Tenant -standardName $StandardName -standardId $Settings.standardId
    }
}
