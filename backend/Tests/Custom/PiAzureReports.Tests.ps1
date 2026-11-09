BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $Helpers = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Custom'
    class HttpResponseContext { [object]$StatusCode; [object]$Body }
    $Accelerators = [PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not ('HttpStatusCode' -as [type])) { $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode]) }
    function Send-PiArmRequest { param($Uri, $Method, $Body, $TenantId) }
    function Test-CIPPAccess { param($Request, [switch]$TenantList) }
    function Get-Tenants { param($TenantFilter) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev) }
    . "$Helpers/AVD/Resolve-PiAvdTenantScope.ps1"
    . "$Helpers/AVD/Get-PiAvdAuthMode.ps1"
    . "$Helpers/Azure/Search-PiAzureReportGraph.ps1"
    . "$Helpers/Azure/Get-PiAzureReport.ps1"
    . "$Helpers/Azure/Get-PiAzureReportResponse.ps1"
    foreach ($Name in 'Retirements', 'Changes') {
        . (Join-Path $BackendRoot "Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Custom/Azure/Invoke-ListPiAzure$Name.ps1")
    }
    $script:TenantA = [pscustomobject]@{ customerId = '11111111-1111-1111-1111-111111111111'; defaultDomainName = 'a.example' }
    $script:TenantB = [pscustomobject]@{ customerId = '22222222-2222-2222-2222-222222222222'; defaultDomainName = 'b.example' }
    $script:SubA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:SubB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:TargetA = "/subscriptions/$script:SubA/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-a"
    $script:TargetB = "/subscriptions/$script:SubB/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-b"
    $script:Now = [datetimeoffset]'2026-11-09T12:00:00Z'
    function New-ReportRequest {
        param([hashtable]$Query = @{ tenantFilter = 'a.example' })
        [pscustomobject]@{ Query = [pscustomobject]$Query; Headers = @{}; Params = @{ CIPPEndpoint = 'ListPiAzureChanges' } }
    }
    function New-Recommendation {
        param([string]$Date = '', [string]$Type = 'retirement-1')
        [pscustomobject]@{ id = 'recommendation-1'; subscriptionId = $script:SubA; resourceId = $script:TargetA; recommendationTypeId = $Type; problem = 'Retiring feature'; solution = 'Upgrade it'; retirementDate = $Date; platformState = 'New' }
    }
}

Describe 'Complete Resource Graph reads' {
    It 'follows continuation tokens and retains explicit subscription scope' {
        Mock Send-PiArmRequest {
            if ($Body.options.'$skipToken') { return @{ data = @(@{ id = 'second' }); resultTruncated = 'false' } }
            @{ data = @(@{ id = 'first' }); '$skipToken' = 'page2'; resultTruncated = 'true' }
        }
        $Rows = @(Search-PiAzureReportGraph -Query 'resources | project id' -TenantId $script:TenantA.customerId -Subscriptions @($script:SubA))
        $Rows.id | Should -Be @('first', 'second')
        Should -Invoke Send-PiArmRequest -Times 2 -ParameterFilter { $Method -eq 'POST' -and $Body.subscriptions[0] -eq $script:SubA }
    }
    It 'rejects silently truncated results' {
        Mock Send-PiArmRequest { @{ data = @(); resultTruncated = 'true' } }
        { Search-PiAzureReportGraph -Query 'resources' -TenantId $script:TenantA.customerId } | Should -Throw '*truncated*'
    }
    It 'rejects a repeating token without returning partial data' {
        Mock Send-PiArmRequest { @{ data = @(@{ id = 'a' }); '$skipToken' = 'repeat' } }
        { Search-PiAzureReportGraph -Query 'resources' -TenantId $script:TenantA.customerId } | Should -Throw '*pagination*'
    }
    It 'rejects malformed responses' {
        Mock Send-PiArmRequest { @{ error = 'unexpected' } }
        { Search-PiAzureReportGraph -Query 'resources' -TenantId $script:TenantA.customerId } | Should -Throw '*envelope*'
    }
}

Describe 'Azure report scope and coverage' {
    BeforeEach {
        Mock Get-PiAvdAuthMode { 'Lighthouse' }
        $env:TenantID = '99999999-9999-9999-9999-999999999999'
        Mock Search-PiAzureReportGraph {
            if ($Query -like 'resourcecontainers*') {
                @(
                    [pscustomobject]@{ subscriptionId = $script:SubA; tenantId = $script:TenantA.customerId; name = 'A subscription' },
                    [pscustomobject]@{ subscriptionId = $script:SubB; tenantId = $script:TenantB.customerId; name = 'B subscription' }
                )
            } elseif ($Query -like '*microsoft.advisor/metadata*') {
                @([pscustomobject]@{ recommendationTypeId = 'retirement-1'; retirementDate = '2026-12-09T00:00:00Z'; trackingIds = @('TRACK-1'); learnMoreLink = 'https://learn.microsoft.com/example' })
            } elseif ($Query -like 'advisorresources*') { @(New-Recommendation) }
            else {
                @([pscustomobject]@{ id = 'change-1'; subscriptionId = $script:SubA; resourceId = $script:TargetA; changeTime = '2026-11-09T10:00:00Z'; changeType = 'Update'; changes = @{ 'properties.size' = @{ previousValue = 'small'; newValue = 'large'; isTruncated = 'true' } } })
            }
        }
    }
    It 'scopes the report query to subscriptions owned by allowed tenants' {
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Retirements -Now $script:Now
        $Report.Items.Count | Should -Be 1
        $Report.Items[0].Tenant | Should -Be 'a.example'
        $Report.Items[0].Deadline | Should -Be '0-30 days'
        $Report.Items[0].DaysRemaining | Should -Be 30
        Should -Invoke Search-PiAzureReportGraph -Times 2 -ParameterFilter { $Query -like 'advisorresources*' -and $Subscriptions.Count -eq 1 -and $Subscriptions[0] -eq $script:SubA }
    }
    It 'drops unexpected out-of-scope rows and cross-subscription targets' {
        Mock Search-PiAzureReportGraph {
            @(
                [pscustomobject]@{ subscriptionId = $script:SubB; resourceId = $script:TargetB },
                [pscustomobject]@{ subscriptionId = $script:SubA; resourceId = $script:TargetB }
            )
        } -ParameterFilter { $Query -like 'resourcechanges*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items.Count | Should -Be 0
        $Report.Coverage.Tenant | Should -Not -Contain 'b.example'
    }
    It 'keeps deleted resources even when there is no current resource inventory row' {
        Mock Search-PiAzureReportGraph { @([pscustomobject]@{ id = 'deleted'; subscriptionId = $script:SubA; resourceId = $script:TargetA; changeType = 'Delete' }) } -ParameterFilter { $Query -like 'resourcechanges*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items[0].ChangeType | Should -Be 'Delete'
        $Report.Items[0].Changes.Count | Should -Be 0
        $Report.Items[0].ChangedBy | Should -Be 'Unspecified'
    }
    It 'preserves before/after values and Azure truncation flags' {
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items[0].Changes[0].Before | Should -Be 'small'
        $Report.Items[0].Changes[0].After | Should -Be 'large'
        $Report.Items[0].Changes[0].Truncated | Should -BeTrue
    }
    It 'accepts PSCustomObject property bags and preserves false and zero' {
        Mock Search-PiAzureReportGraph { @([pscustomobject]@{ subscriptionId = $script:SubA; resourceId = $script:TargetA; changes = [pscustomobject]@{ flag = [pscustomobject]@{ previousValue = $false; newValue = 0 } } }) } -ParameterFilter { $Query -like 'resourcechanges*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items[0].Changes[0].Before | Should -BeFalse
        $Report.Items[0].Changes[0].After | Should -Be 0
    }
    It 'filters a resource locally without interpolating the requested resource into KQL' {
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes -ResourceId "$($script:TargetA)' | take 1"
        $Report.Items.Count | Should -Be 0
        Should -Invoke Search-PiAzureReportGraph -Times 1 -ParameterFilter { $Query -like 'resourcechanges*' -and $Query -notlike '*take 1*' }
    }
    It 'normalizes native JSON dates without culture-dependent output and distinguishes missing values' {
        Mock Search-PiAzureReportGraph { @([pscustomobject]@{ subscriptionId = $script:SubA; resourceId = $script:TargetA; changeTime = [datetime]'2026-11-09T10:00:00Z'; changes = @{ field = @{ newValue = $null } } }) } -ParameterFilter { $Query -like 'resourcechanges*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items[0].ChangeTime | Should -BeLike '2026-11-09T10:00:00*'
        $Report.Items[0].Changes[0].BeforeProvided | Should -BeFalse
        $Report.Items[0].Changes[0].AfterProvided | Should -BeTrue
    }
    It 'retains resource matching across case and trailing slash differences' {
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes -ResourceId "$($script:TargetA.ToUpperInvariant())/"
        $Report.Items.Count | Should -Be 1
    }
    It 'reports no visible subscriptions as unknown instead of healthy' {
        Mock Search-PiAzureReportGraph { @() } -ParameterFilter { $Query -like 'resourcecontainers*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Items.Count | Should -Be 0
        $Report.Coverage[0].Status | Should -Be 'Unknown'
        Should -Invoke Search-PiAzureReportGraph -Times 0 -ParameterFilter { $Query -like 'resourcechanges*' }
    }
    It 'shows subscription discovery failures without leaking raw error text' {
        Mock Search-PiAzureReportGraph { throw 'other-tenant-private-id' } -ParameterFilter { $Query -like 'resourcecontainers*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        $Report.Coverage[0].Status | Should -Be 'Unavailable'
        ($Report | ConvertTo-Json -Depth 10) | Should -Not -Match 'other-tenant-private-id'
    }
    It 'shows query failures instead of a successful empty report' {
        Mock Search-PiAzureReportGraph { throw 'Forbidden' } -ParameterFilter { $Query -like 'resourcechanges*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Changes
        ($Report.Coverage | Where-Object Source -EQ Changes).Status | Should -Be 'Unavailable'
    }
    It 'retains recommendations when retirement metadata cannot be read' {
        Mock Search-PiAzureReportGraph { throw 'Forbidden' } -ParameterFilter { $Query -like '*microsoft.advisor/metadata*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Retirements
        $Report.Items.Count | Should -Be 1
        $Report.Items[0].Deadline | Should -Be 'Unknown'
        $Report.Items[0].DaysRemaining | Should -BeNullOrEmpty
        ($Report.Coverage | Where-Object Source -EQ 'Retirement metadata').Status | Should -Be 'Unavailable'
    }
    It 'keeps unmatched metadata and malformed dates unknown' {
        Mock Search-PiAzureReportGraph { @(New-Recommendation -Date 'not-a-date' -Type 'unmapped') } -ParameterFilter { $Query -like '*microsoft.advisor/recommendations*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Retirements
        $Report.Items[0].Deadline | Should -Be 'Unknown'
    }
    It 'buckets UTC calendar deadlines at the boundaries' {
        Mock Search-PiAzureReportGraph { @() } -ParameterFilter { $Query -like '*microsoft.advisor/metadata*' }
        Mock Search-PiAzureReportGraph {
            @(-1, 0, 30, 31, 60, 61, 90, 91 | ForEach-Object { New-Recommendation -Date $script:Now.AddDays($_).ToString('o') })
        } -ParameterFilter { $Query -like '*microsoft.advisor/recommendations*' }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA) -Kind Retirements -Now $script:Now
        $Report.Items.Deadline | Should -Be @('Overdue', '0-30 days', '0-30 days', '31-60 days', '31-60 days', '61-90 days', '61-90 days', 'Later')
    }
    It 'isolates per-tenant token failures while preserving another customers results' {
        Mock Get-PiAvdAuthMode { 'Tenant' }
        Mock Search-PiAzureReportGraph { throw 'Denied B' } -ParameterFilter { $TenantId -eq $script:TenantB.customerId }
        $Report = Get-PiAzureReport -Tenants @($script:TenantA, $script:TenantB) -Kind Changes
        $Report.Items.Count | Should -Be 1
        $Report.Items[0].Tenant | Should -Be 'a.example'
        ($Report.Coverage | Where-Object Tenant -EQ 'b.example').Status | Should -Be 'Unavailable'
        Should -Invoke Search-PiAzureReportGraph -Times 1 -ParameterFilter { $Query -like 'resourcechanges*' -and $Subscriptions.Count -eq 1 -and $Subscriptions[0] -eq $script:SubA -and $TenantId -eq $script:TenantA.customerId }
    }
}

Describe 'Azure report endpoint validation' {
    BeforeEach {
        Mock Get-Tenants { @($script:TenantA, $script:TenantB) }
        Mock Test-CIPPAccess { @($script:TenantA.customerId) }
        Mock Get-PiAzureReport { [pscustomobject]@{ Items = @(); Coverage = @() } }
    }
    It 'resolves AllTenants through the callers allowed tenant list' {
        $Response = Invoke-ListPiAzureRetirements -Request (New-ReportRequest @{ tenantFilter = 'AllTenants' })
        $Response.StatusCode | Should -Be 200
        Should -Invoke Get-PiAzureReport -Times 1 -ParameterFilter { $Tenants.Count -eq 1 -and $Tenants[0].customerId -eq $script:TenantA.customerId -and $Kind -eq 'Retirements' }
    }
    It 'rejects an inaccessible tenant before querying Azure' {
        Mock Get-Tenants { @($script:TenantB) }
        $Response = Invoke-ListPiAzureChanges -Request (New-ReportRequest @{ tenantFilter = 'b.example' })
        $Response.StatusCode | Should -Be 403
        Should -Invoke Get-PiAzureReport -Times 0
    }
    It 'rejects invalid windows and missing tenant filters' -ForEach @(
        @{ Query = @{ tenantFilter = 'a.example'; days = '30' } },
        @{ Query = @{ tenantFilter = 'a.example'; days = '1) | take 1' } },
        @{ Query = @{} }
    ) {
        (Invoke-ListPiAzureChanges -Request (New-ReportRequest $Query)).StatusCode | Should -Be 400
        Should -Invoke Get-PiAzureReport -Times 0
    }
    It 'passes the explicit window and resource filter to the read-only report' {
        (Invoke-ListPiAzureChanges -Request (New-ReportRequest @{ tenantFilter = 'a.example'; days = '14'; resourceId = $script:TargetA })).StatusCode | Should -Be 200
        Should -Invoke Get-PiAzureReport -Times 1 -ParameterFilter { $Kind -eq 'Changes' -and $Days -eq 14 -and $ResourceId -eq $script:TargetA }
    }
}
