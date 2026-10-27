# Pester tests for the fork's AVD module (Prometheus Informatik).
#
# Same pattern as upstream's endpoint tests: dot-source the files under test, stub every CIPP
# dependency, and pin the behaviour that matters most - request validation, tenant isolation,
# and the guard that stops a restart from kicking signed-in users.

BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $HelperRoot = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Custom/AVD'
    $EntryRoot = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Custom/AVD'
    if (-not (Test-Path $HelperRoot)) { throw "AVD helpers not found at $HelperRoot" }
    if (-not (Test-Path $EntryRoot)) { throw "AVD entrypoints not found at $EntryRoot" }

    class HttpResponseContext {
        [object]$StatusCode
        [object]$Body
    }
    $Accelerators = [PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not ('HttpStatusCode' -as [type])) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    # Lighthouse mode (the default) queries from the partner tenant; mocks keep the real
    # functions' mandatory-parameter validation, so the partner tenant id must be set.
    $env:TenantID = '99999999-9999-9999-9999-999999999999'
    $env:PiAvdArmAuthMode = $null

    # CIPP dependencies
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = $Exception.Exception.Message } }
    function Test-CIPPAccess { param($Request, [switch]$TenantList) }
    function Get-Tenants { param($TenantFilter, [switch]$IncludeErrors) }
    function Get-GraphToken { param($tenantid, $scope, $AsApp) @{ Authorization = 'Bearer test' } }

    # Helpers that endpoint tests replace with mocks; the real files are dot-sourced below
    # and override these for the helper tests.
    function Send-PiArmRequest { param($Uri, $Method, $Body, $TenantId, [switch]$All) }

    foreach ($File in 'Get-PiAvdApiVersion', 'Get-PiAvdAuthMode', 'Resolve-PiAvdTenantScope', 'Assert-PiAvdResourceTenant', 'Get-PiAvdHostPool', 'Search-PiResourceGraph') {
        . (Join-Path $HelperRoot "$File.ps1")
    }
    foreach ($File in 'Invoke-ExecPiAvdUserSession', 'Invoke-ExecPiAvdSessionHost') {
        . (Join-Path $EntryRoot "$File.ps1")
    }

    $script:TenantA = [pscustomobject]@{ customerId = '11111111-1111-1111-1111-111111111111'; defaultDomainName = 'a.example'; displayName = 'Tenant A' }
    $script:TenantB = [pscustomobject]@{ customerId = '22222222-2222-2222-2222-222222222222'; defaultDomainName = 'b.example'; displayName = 'Tenant B' }
    $script:SubA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:SessionId = "/subscriptions/$($script:SubA)/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp1/sessionHosts/avd-0.a.example/userSessions/3"
    $script:HostId = "/subscriptions/$($script:SubA)/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp1/sessionHosts/avd-0.a.example"
    $script:VmId = "/subscriptions/$($script:SubA)/resourceGroups/rg-avd/providers/Microsoft.Compute/virtualMachines/avd-0"

    function New-PiRequest {
        param([hashtable]$Body = @{}, [string]$Endpoint = 'ExecPiAvdUserSession')
        [pscustomobject]@{
            Body    = [pscustomobject]$Body
            Query   = [pscustomobject]@{}
            Params  = [pscustomobject]@{ CIPPEndpoint = $Endpoint }
            Headers = @{}
        }
    }
}

Describe 'Resolve-PiAvdTenantScope' {
    BeforeEach {
        Mock -CommandName Get-Tenants -MockWith { if ($TenantFilter) { @($script:TenantA) } else { @($script:TenantA, $script:TenantB) } }
    }

    It 'returns every tenant for an unrestricted user on AllTenants' {
        Mock -CommandName Test-CIPPAccess -MockWith { @('AllTenants') }
        $Result = Resolve-PiAvdTenantScope -Request (New-PiRequest) -TenantFilter 'AllTenants'
        @($Result).Count | Should -Be 2
    }

    It 'drops tenants the user is not scoped to' {
        Mock -CommandName Test-CIPPAccess -MockWith { @($script:TenantB.customerId) }
        $Result = Resolve-PiAvdTenantScope -Request (New-PiRequest) -TenantFilter 'AllTenants'
        @($Result).customerId | Should -Be @($script:TenantB.customerId)
    }

    It 'throws when the requested tenant is out of scope' {
        Mock -CommandName Test-CIPPAccess -MockWith { @($script:TenantB.customerId) }
        { Resolve-PiAvdTenantScope -Request (New-PiRequest) -TenantFilter 'a.example' } | Should -Throw '*not found or you do not have access*'
    }
}

Describe 'Assert-PiAvdResourceTenant' {
    It 'passes when the subscription belongs to the tenant' {
        Mock -CommandName Search-PiResourceGraph -MockWith { @([pscustomobject]@{ tenantId = $script:TenantA.customerId }) }
        { Assert-PiAvdResourceTenant -ResourceId $script:SessionId -TenantId $script:TenantA.customerId } | Should -Not -Throw
    }

    It 'throws when the subscription belongs to another tenant' {
        Mock -CommandName Search-PiResourceGraph -MockWith { @([pscustomobject]@{ tenantId = $script:TenantB.customerId }) }
        { Assert-PiAvdResourceTenant -ResourceId $script:SessionId -TenantId $script:TenantA.customerId } | Should -Throw '*does not belong*'
    }

    It 'throws when the subscription is not visible at all' {
        Mock -CommandName Search-PiResourceGraph -MockWith { @() }
        { Assert-PiAvdResourceTenant -ResourceId $script:SessionId -TenantId $script:TenantA.customerId } | Should -Throw '*does not belong*'
    }

    It 'rejects ids that are not subscription-scoped' {
        { Assert-PiAvdResourceTenant -ResourceId '/providers/Microsoft.Foo/bar' -TenantId $script:TenantA.customerId } | Should -Throw 'Invalid resource id.'
    }
}

Describe 'Get-PiAvdHostPool' {
    It 'keeps only pools from in-scope tenants and tags them' {
        Mock -CommandName Search-PiResourceGraph -MockWith {
            @(
                [pscustomobject]@{ id = '/x/hp-a'; name = 'hp-a'; tenantId = $script:TenantA.customerId },
                [pscustomobject]@{ id = '/x/hp-b'; name = 'hp-b'; tenantId = $script:TenantB.customerId },
                [pscustomobject]@{ id = '/x/hp-c'; name = 'hp-c'; tenantId = '33333333-3333-3333-3333-333333333333' }
            )
        }
        $Result = @(Get-PiAvdHostPool -Tenants @($script:TenantA))
        $Result.Count | Should -Be 1
        $Result[0].name | Should -Be 'hp-a'
        $Result[0].Tenant | Should -Be 'a.example'
    }
}

Describe 'Invoke-ExecPiAvdUserSession' {
    BeforeEach {
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName Resolve-PiAvdTenantScope -MockWith { @($script:TenantA) }
        Mock -CommandName Assert-PiAvdResourceTenant -MockWith { }
        Mock -CommandName Send-PiArmRequest -MockWith { $null }
    }

    It 'refuses AllTenants' {
        $Response = Invoke-ExecPiAvdUserSession -Request (New-PiRequest -Body @{ tenantFilter = 'AllTenants'; ID = $script:SessionId; Action = 'logoff' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        Should -Invoke Send-PiArmRequest -Times 0
    }

    It 'refuses ids that are not user sessions' {
        $Response = Invoke-ExecPiAvdUserSession -Request (New-PiRequest -Body @{ tenantFilter = 'a.example'; ID = $script:HostId; Action = 'logoff' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        Should -Invoke Send-PiArmRequest -Times 0
    }

    It 'requires title and body for sendMessage' {
        $Response = Invoke-ExecPiAvdUserSession -Request (New-PiRequest -Body @{ tenantFilter = 'a.example'; ID = $script:SessionId; Action = 'sendMessage'; MessageTitle = 'Hi' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
    }

    It 'logs off with a forced DELETE after the tenant check' {
        $Response = Invoke-ExecPiAvdUserSession -Request (New-PiRequest -Body @{ tenantFilter = 'a.example'; ID = $script:SessionId; Action = 'logoff'; UserPrincipalName = 'user@a.example' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Response.Body.Results | Should -BeLike 'Logged off user@a.example*'
        Should -Invoke Assert-PiAvdResourceTenant -Times 1 -ParameterFilter { $TenantId -eq $script:TenantA.customerId }
        Should -Invoke Send-PiArmRequest -Times 1 -ParameterFilter { $Method -eq 'DELETE' -and $Uri -like '*force=true*' }
    }

    It 'does not call ARM when the tenant check fails' {
        Mock -CommandName Assert-PiAvdResourceTenant -MockWith { throw 'The resource does not belong to the selected tenant' }
        $Response = Invoke-ExecPiAvdUserSession -Request (New-PiRequest -Body @{ tenantFilter = 'a.example'; ID = $script:SessionId; Action = 'disconnect' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::InternalServerError)
        Should -Invoke Send-PiArmRequest -Times 0
    }
}

Describe 'Invoke-ExecPiAvdSessionHost' {
    BeforeEach {
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName Resolve-PiAvdTenantScope -MockWith { @($script:TenantA) }
        Mock -CommandName Assert-PiAvdResourceTenant -MockWith { }
    }

    It 'turns drain mode on with allowNewSession false' {
        Mock -CommandName Send-PiArmRequest -MockWith { $null }
        $Response = Invoke-ExecPiAvdSessionHost -Request (New-PiRequest -Endpoint 'ExecPiAvdSessionHost' -Body @{ tenantFilter = 'a.example'; ID = $script:HostId; Action = 'drainOn' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        Should -Invoke Send-PiArmRequest -Times 1 -ParameterFilter { $Method -eq 'PATCH' -and $Body.properties.allowNewSession -eq $false }
    }

    It 'refuses to restart a host with sessions unless forced' {
        Mock -CommandName Send-PiArmRequest -MockWith {
            if ($Method -eq 'POST') { throw 'restart must not be called' }
            [pscustomobject]@{ properties = [pscustomobject]@{ sessions = 2; resourceId = $script:VmId } }
        }
        $Response = Invoke-ExecPiAvdSessionHost -Request (New-PiRequest -Endpoint 'ExecPiAvdSessionHost' -Body @{ tenantFilter = 'a.example'; ID = $script:HostId; Action = 'restart' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::Conflict)
    }

    It 'restarts when forced' {
        Mock -CommandName Send-PiArmRequest -MockWith {
            if ($Method -eq 'POST') { return $null }
            [pscustomobject]@{ properties = [pscustomobject]@{ sessions = 2; resourceId = $script:VmId } }
        }
        $Response = Invoke-ExecPiAvdSessionHost -Request (New-PiRequest -Endpoint 'ExecPiAvdSessionHost' -Body @{ tenantFilter = 'a.example'; ID = $script:HostId; Action = 'restart'; Force = $true })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        Should -Invoke Send-PiArmRequest -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Uri -like "*$($script:VmId)/restart?*" }
    }
}
