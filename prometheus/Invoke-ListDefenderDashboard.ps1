function Invoke-ListDefenderDashboard {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Security.DefenderDashboard.Read
    .DESCRIPTION
        Fixed read-only Defender inventory for the Prometheus dashboard. No arbitrary URLs, token export or remediation.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    if ($Request.Method -ne 'GET') {
        return ([HttpResponseContext]@{ StatusCode = 405; Body = @{ error = 'Only GET is supported.' } })
    }
    $Workload = [string]$Request.Query.Workload
    if ($Workload -notin @('customers', 'endpoints', 'cloud')) {
        return ([HttpResponseContext]@{ StatusCode = 400; Body = @{ error = 'Unknown workload.' } })
    }
    $Allowed = @(Test-CIPPAccess -Request $Request -TenantList)
    $Tenants = @(Get-Tenants -IncludeErrors -SkipDomains | Where-Object {
            $Allowed -contains 'AllTenants' -or $Allowed -contains $_.customerId
        } | ForEach-Object {
            @{ id = ([string]$_.customerId).ToLowerInvariant(); name = $_.displayName; source = 'CIPP'; relationships = @() }
        })
    if ($Allowed -contains 'AllTenants' -or $Allowed -contains $env:TenantID) {
        if ($Tenants.id -notcontains $env:TenantID) {
            $Tenants += @{ id = $env:TenantID.ToLowerInvariant(); name = 'Prometheus Informatik AG'; source = 'Home tenant'; relationships = @() }
        }
    }
    if ($Workload -eq 'customers') {
        return ([HttpResponseContext]@{ StatusCode = 200; Body = @{ customers = @($Tenants | Sort-Object name) } })
    }
    $Tenant = ([string]$Request.Query.TenantFilter).ToLowerInvariant()
    if ($Tenant -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $Tenants.id -notcontains $Tenant) {
        return ([HttpResponseContext]@{ StatusCode = 404; Body = @{ error = 'Unknown or unauthorized tenant.' } })
    }

    function Read-DashboardCollection {
        param([string]$Uri, [hashtable]$Headers)
        $Origin = ([uri]$Uri).GetLeftPart([System.UriPartial]::Authority)
        $Items = [System.Collections.Generic.List[object]]::new()
        $Pages = 0
        while ($Uri) {
            $Address = [uri]$Uri
            if ($Address.GetLeftPart([System.UriPartial]::Authority) -cne $Origin -or $Address.UserInfo -or ++$Pages -gt 100) {
                throw 'Invalid pagination address or page limit exceeded.'
            }
            $Page = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -TimeoutSec 25 -MaximumRedirection 0 -ErrorAction Stop
            if ($null -eq $Page.value -or $Page.value -isnot [System.Collections.IList]) { throw 'Invalid collection response.' }
            foreach ($Item in $Page.value) { $Items.Add($Item) }
            $Uri = $Page.'@odata.nextLink' ?? $Page.nextLink
        }
        return ,$Items.ToArray()
    }
    function Read-DashboardSource {
        param([string]$Uri, [string]$Scope)
        $Checked = [datetime]::UtcNow.ToString('o')
        try {
            $Headers = Get-GraphToken -tenantid $Tenant -scope $Scope
            $Data = Read-DashboardCollection -Uri $Uri -Headers $Headers
            return @{ status = 'ok'; data = @($Data); checkedAt = $Checked }
        } catch {
            $Code = [int]$_.Exception.Response.StatusCode
            $IdentityCode = [regex]::Match([string]$_.Exception.Message, 'AADSTS\d+').Value
            return @{
                status = $(if ($Code -eq 403) { 'forbidden' } else { 'error' })
                code = $(if ($IdentityCode) { "cipp_$IdentityCode" } else { "cipp_source_$Code" })
                message = 'CIPP could not read this source. The administrator must check its SAM consent, GDAP role, Azure RBAC or workload availability.'
                checkedAt = $Checked
            }
        }
    }
    if ($Workload -eq 'endpoints') {
        $Machines = Read-DashboardSource -Uri 'https://api.securitycenter.microsoft.com/api/machines?$top=10000' -Scope 'https://api.securitycenter.microsoft.com/.default'
        $Alerts = Read-DashboardSource -Uri "https://api.securitycenter.microsoft.com/api/alerts?`$filter=status ne 'Resolved'&`$top=1000" -Scope 'https://api.securitycenter.microsoft.com/.default'
        $Summary = if ($Machines.status -eq 'ok') {
            @{
                total = @($Machines.data).Count
                servers = @($Machines.data | Where-Object osPlatform -Match 'server|linux').Count
                highRisk = @($Machines.data | Where-Object riskScore -In @('High', 'Medium')).Count
                unhealthy = @($Machines.data | Where-Object healthStatus -NE 'Active').Count
                onboarded = @($Machines.data | Where-Object onboardingStatus -EQ 'Onboarded').Count
            }
        } else { $null }
        $Result = @{ machines = $Machines; alerts = $Alerts; summary = $Summary }
    } else {
        # ARM's resource identifier includes its trailing slash. Preserve it
        # before appending /.default so Entra resolves the consented resource.
        $Scope = 'https://management.azure.com//.default'
        $Subscriptions = Read-DashboardSource -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01' -Scope $Scope
        $Items = @()
        if ($Subscriptions.status -eq 'ok') {
            # Cross-tenant Lighthouse resources must appear under their own tenant selection.
            $Subscriptions.data = @($Subscriptions.data | Where-Object { $_.state -eq 'Enabled' -and $_.tenantId -eq $Tenant })
            foreach ($Subscription in $Subscriptions.data) {
                if ($Subscription.subscriptionId -notmatch '^[0-9a-fA-F-]{36}$') { continue }
                $Prefix = "https://management.azure.com/subscriptions/$($Subscription.subscriptionId)"
                $Paths = @{
                    plans = '/providers/Microsoft.Security/pricings?api-version=2024-01-01'
                    scores = '/providers/Microsoft.Security/secureScores?api-version=2020-01-01'
                    alerts = '/providers/Microsoft.Security/alerts?api-version=2022-01-01'
                    virtualMachines = "/resources?api-version=2021-04-01&`$filter=resourceType eq 'Microsoft.Compute/virtualMachines'"
                    arcMachines = "/resources?api-version=2021-04-01&`$filter=resourceType eq 'Microsoft.HybridCompute/machines'"
                }
                $Item = @{ subscription = $Subscription }
                foreach ($Key in $Paths.Keys) { $Item[$Key] = Read-DashboardSource -Uri ($Prefix + $Paths[$Key]) -Scope $Scope }
                $Items += $Item
            }
        }
        $Result = @{ subscriptions = $Subscriptions; items = @($Items) }
    }
    return ([HttpResponseContext]@{ StatusCode = 200; Body = $Result })
}
