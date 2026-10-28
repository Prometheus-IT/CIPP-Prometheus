function Send-PiAvdStandardArmRequest {
    <#
    .SYNOPSIS
        Calls Azure Resource Manager for the AVD standards, retrying throttling and transient errors.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Same behaviour as the AVD module's
        Send-PiArmRequest, kept separate because that helper lives in CIPPHTTP.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PATCH')]
        [string]$Method = 'GET',

        [object]$Body,

        [Parameter(Mandatory = $true)]
        [string]$TokenTenant,

        [switch]$All,

        [int]$MaxRetries = 4
    )

    $Headers = Get-GraphToken -tenantid $TokenTenant -scope 'https://management.azure.com/.default' -AsApp $true
    $BodyString = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { $null }
    $Collected = [System.Collections.Generic.List[object]]::new()
    $NextUri = $Uri

    do {
        $Attempt = 0
        while ($true) {
            $Attempt++
            $RestParams = @{ Uri = $NextUri; Method = $Method; Headers = $Headers }
            if ($BodyString) {
                $RestParams.Body = $BodyString
                $RestParams.ContentType = 'application/json'
            }
            try {
                $Response = Invoke-CIPPRestMethod @RestParams
                break
            } catch {
                $ErrorResponse = $_.Exception.Response
                $Status = [int]($ErrorResponse.StatusCodeValue ?? $ErrorResponse.StatusCode ?? 0)
                if ($Status -in @(429, 500, 502, 503, 504) -and $Attempt -le $MaxRetries) {
                    $RetryAfter = 0
                    $RetryHeader = try { $ErrorResponse.Headers['Retry-After'] } catch { $null }
                    if (-not ([int]::TryParse([string]$RetryHeader, [ref]$RetryAfter))) { $RetryAfter = 0 }
                    Start-Sleep -Seconds ([math]::Max($RetryAfter, [math]::Min([math]::Pow(2, $Attempt), 30)))
                    continue
                }
                $RawBody = $_.ErrorDetails.Message ?? $ErrorResponse.Content
                $ArmError = try { ($RawBody | ConvertFrom-Json -ErrorAction Stop).error } catch { $null }
                throw "ARM $Method failed ($Status $($ArmError.code ?? 'Unknown')): $($ArmError.message ?? $RawBody ?? $_.Exception.Message)"
            }
        }
        if (-not $All.IsPresent) { return $Response }
        foreach ($Item in @($Response.value)) { if ($null -ne $Item) { $Collected.Add($Item) } }
        $NextUri = $Response.nextLink
    } while (-not [string]::IsNullOrWhiteSpace($NextUri))

    return $Collected.ToArray()
}
