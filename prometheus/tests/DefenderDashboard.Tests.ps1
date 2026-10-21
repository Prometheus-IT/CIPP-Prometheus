BeforeAll {
    if (-not ('HttpResponseContext' -as [type])) {
        Add-Type 'public class HttpResponseContext { public int StatusCode; public object Body; }'
    }
    function Test-CIPPAccess { param($Request, [switch]$TenantList) }
    function Get-Tenants { param([switch]$IncludeErrors, [switch]$SkipDomains) }
    function Get-GraphToken { param($tenantid, $scope) }
    . "$PSScriptRoot/../Invoke-ListDefenderDashboard.ps1"
}
Describe 'Read-only Defender dashboard boundary' {
    BeforeEach {
        $env:TenantID = '43c3a427-8569-4d33-ae1b-b6e4e3220f09'
        $script:customer = '00000000-0000-0000-0000-000000000002'
        Mock Test-CIPPAccess { @('AllTenants') }
        Mock Get-Tenants { @([pscustomobject]@{ customerId = $script:customer; displayName = 'Customer' }) }
        Mock Get-GraphToken { @{ Authorization = 'Bearer test' } }
        Mock Invoke-RestMethod { @{ value = @() } }
    }
    It 'rejects every mutation before querying tenants or tokens' {
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'POST'; Query = @{ Workload = 'endpoints' } }
        $r.StatusCode | Should -Be 405
        Should -Invoke Get-GraphToken -Times 0
        Should -Invoke Get-Tenants -Times 0
    }
    It 'rejects unknown tenants before acquiring customer credentials' {
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'endpoints'; TenantFilter = '00000000-0000-0000-0000-000000000003' } }
        $r.StatusCode | Should -Be 404
        Should -Invoke Get-GraphToken -Times 0
    }
    It 'honors the API client tenant scope in customer discovery' {
        Mock Test-CIPPAccess { @($script:customer) }
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'customers' } }
        @($r.Body.customers).Count | Should -Be 1
        $r.Body.customers[0].id | Should -Be $script:customer
    }
    It 'never forwards SAM credentials to a foreign pagination origin' {
        Mock Invoke-RestMethod { @{ value = @(@{ id = 'device' }); '@odata.nextLink' = 'https://attacker.invalid/steal' } }
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'endpoints'; TenantFilter = $script:customer } }
        $r.Body.machines.status | Should -Be 'error'
        $r.Body.summary | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 2
    }
    It 'does not turn malformed or failed inventory into zero devices' {
        Mock Invoke-RestMethod { @{ error = @{ message = 'permission denied' } } }
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'endpoints'; TenantFilter = $script:customer } }
        $r.Body.machines.status | Should -Be 'error'
        $r.Body.summary | Should -BeNullOrEmpty
    }
    It 'collects every page before calculating device totals' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*page=2') { @{ value = @(@{ id = 'two'; healthStatus = 'Active' }) } }
            elseif ($Uri -like '*/api/machines*') { @{ value = @(@{ id = 'one'; healthStatus = 'Active' }); '@odata.nextLink' = 'https://api.securitycenter.microsoft.com/api/machines?page=2' } }
            else { @{ value = @() } }
        }
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'endpoints'; TenantFilter = $script:customer } }
        $r.Body.machines.status | Should -Be 'ok'
        $r.Body.summary.total | Should -Be 2
    }
    It 'preserves the ARM resource slash and filters subscriptions to the selected tenant' {
        Mock Get-GraphToken {
            if ($scope -ne 'https://management.azure.com//.default') { throw 'ARM resource audience lost its trailing slash' }
            @{ Authorization = 'Bearer test' }
        }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/subscriptions?*') {
                @{ value = @(
                        @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; tenantId = $script:customer; state = 'Enabled' },
                        @{ subscriptionId = '22222222-2222-2222-2222-222222222222'; tenantId = 'other-tenant'; state = 'Enabled' }
                    ) }
            } else { @{ value = @() } }
        }
        $r = Invoke-ListDefenderDashboard -Request @{ Method = 'GET'; Query = @{ Workload = 'cloud'; TenantFilter = $script:customer } }
        $r.Body.subscriptions.status | Should -Be 'ok'
        @($r.Body.subscriptions.data).Count | Should -Be 1
        @($r.Body.items).Count | Should -Be 1
        Should -Invoke Get-GraphToken -Times 6
    }
}
