function Send-PiArmRequest {
    <#
    .SYNOPSIS
        Calls Azure Resource Manager with retry on throttling and optional nextLink paging.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Uses Invoke-CIPPRestMethod (pooled HttpClient)
        and the token from Get-PiArmToken. Retries 429/500/502/503/504 honouring Retry-After,
        throws on any other non-2xx with the ARM error message.

        Deliberately not named Invoke-*: the CIPP router maps /api/<X> to Invoke-<X>, so
        helpers must never use that verb.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [object]$Body,

        # Customer tenant id (used for the token in Tenant auth mode).
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        # Follow nextLink and return the concatenated .value arrays.
        [switch]$All,

        [int]$MaxRetries = 4
    )

    $Headers = Get-PiArmToken -TenantId $TenantId
    $BodyString = $null
    if ($null -ne $Body) {
        $BodyString = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $Collected = [System.Collections.Generic.List[object]]::new()
    $NextUri = $Uri

    do {
        $Attempt = 0
        while ($true) {
            $Attempt++
            $RestParams = @{
                Uri     = $NextUri
                Method  = $Method
                Headers = $Headers
            }
            if ($BodyString) {
                $RestParams.Body = $BodyString
                $RestParams.ContentType = 'application/json'
            }

            # Status and headers are read from the exception, the same way New-GraphGetRequest
            # does it. -StatusCodeVariable is not used on purpose: Invoke-CIPPRestMethod lives in
            # CIPPCore and sets that variable with Set-Variable -Scope 1, which lands in
            # CIPPCore's module scope, not in this CIPPHTTP function.
            try {
                $Response = Invoke-CIPPRestMethod @RestParams
                break
            } catch {
                $ErrorResponse = $_.Exception.Response
                $Status = [int]($ErrorResponse.StatusCodeValue ?? $ErrorResponse.StatusCode ?? 0)

                $Retryable = $Status -in @(429, 500, 502, 503, 504)
                if ($Retryable -and $Attempt -le $MaxRetries) {
                    $RetryAfter = 0
                    $RetryHeader = try { $ErrorResponse.Headers['Retry-After'] } catch { $null }
                    if (-not ([int]::TryParse([string]$RetryHeader, [ref]$RetryAfter))) { $RetryAfter = 0 }
                    # Exponential backoff, capped; Retry-After wins when ARM sends one.
                    $Delay = [math]::Max($RetryAfter, [math]::Min([math]::Pow(2, $Attempt), 30))
                    Write-Information "ARM $Status on $Method $NextUri - retry $Attempt/$MaxRetries in $Delay s"
                    Start-Sleep -Seconds $Delay
                    continue
                }

                $RawBody = $_.ErrorDetails.Message ?? $ErrorResponse.Content
                $ArmError = try { ($RawBody | ConvertFrom-Json -ErrorAction Stop).error } catch { $null }
                $ArmMessage = $ArmError.message ?? $RawBody ?? $_.Exception.Message
                $ArmCode = $ArmError.code ?? 'Unknown'
                throw "ARM $Method failed ($Status $ArmCode): $ArmMessage"
            }
        }

        if (-not $All.IsPresent) { return $Response }

        foreach ($Item in @($Response.value)) {
            if ($null -ne $Item) { $Collected.Add($Item) }
        }
        $NextUri = $Response.nextLink
    } while (-not [string]::IsNullOrWhiteSpace($NextUri))

    return $Collected.ToArray()
}
