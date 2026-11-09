function Get-PiAzureReportResponse {
    <#
    .SYNOPSIS
        Shared read-only request validation for Azure reports.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param($Request, [ValidateSet('Retirements', 'Changes')] [string]$Kind)

    $TenantFilter = [string]$Request.Query.tenantFilter
    $Days = 7
    $ResourceId = [string]$Request.Query.resourceId
    if ([string]::IsNullOrWhiteSpace($TenantFilter) -or
        ($Request.Query.days -and [string]$Request.Query.days -notin @('1', '7', '14')) -or
        ($ResourceId -and ($Kind -ne 'Changes' -or $ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/[^\r\n?#]+$'))) {
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'Select a tenant, a 1, 7 or 14 day window, and an optional Azure resource ID for changes.' } })
    }
    if ($Request.Query.days) { $Days = [int]$Request.Query.days }
    try {
        $Tenants = @(Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter)
    } catch {
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = @{ Results = 'Tenant was not found or access was denied.' } })
    }
    try {
        $Body = Get-PiAzureReport -Tenants $Tenants -Kind $Kind -Days $Days -ResourceId $ResourceId
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $Body })
    } catch {
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -tenant $TenantFilter -message "Azure $Kind report failed." -Sev 'Error'
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::InternalServerError; Body = @{ Results = 'Azure report could not be read. Retry or check Azure access.' } })
    }
}
