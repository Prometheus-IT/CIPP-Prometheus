# Pester tests for the fork's Azure Lighthouse onboarding page and Windows 365 view
# (Prometheus Informatik).
#
# Pins the behaviour that matters: unknown or invisible access is never reported as healthy,
# the generated template matches the delegation the AVD module needs, and a tenant that
# cannot be read is an error rather than an empty list.

BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $AvdRoot = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Custom/AVD'
    $AzureRoot = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Custom/Azure'
    $EntryRoot = Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Custom'

    class HttpResponseContext {
        [object]$StatusCode
        [object]$Body
    }
    $Accelerators = [PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not ('HttpStatusCode' -as [type])) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    $env:TenantID = '99999999-9999-9999-9999-999999999999'
    $env:ApplicationID = '88888888-8888-8888-8888-888888888888'
    $env:PiAvdArmAuthMode = $null
    $env:PiAvdLighthousePrincipalId = $null

    # CIPP dependencies
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = $Exception.Exception.Message } }
    function New-GraphGetRequest { param($uri, $tenantid, $NoAuthCheck, $extraHeaders) }
    function Test-CIPPCloudPCDevice { param($Device) $Device.model -like 'Cloud PC*' }
    function Search-PiResourceGraph { param($Query, $TenantId) }
    function Send-PiArmRequest { param($Uri, $Method, $Body, $TenantId, [switch]$All) }
    function Resolve-PiAvdTenantScope { param($Request, $TenantFilter) }

    . (Join-Path $AvdRoot 'Get-PiAvdAuthMode.ps1')
    foreach ($File in 'Get-PiLighthouseRoles', 'Get-PiLighthousePrincipal', 'Get-PiLighthouseTemplate', 'Get-PiAzureAccessStatus') {
        . (Join-Path $AzureRoot "$File.ps1")
    }
    . (Join-Path $EntryRoot 'Azure/Invoke-ListPiAzureLighthouseTemplate.ps1')
    . (Join-Path $EntryRoot 'W365/Invoke-ListPiCloudPCs.ps1')

    $script:Principal = [pscustomobject]@{ PrincipalId = '77777777-7777-7777-7777-777777777777'; DisplayName = 'CIPP-SAM'; Source = 'SamServicePrincipal' }
    $script:TenantA = [pscustomobject]@{ customerId = '11111111-1111-1111-1111-111111111111'; defaultDomainName = 'a.example'; displayName = 'Tenant A' }
    $script:TenantB = [pscustomobject]@{ customerId = '22222222-2222-2222-2222-222222222222'; defaultDomainName = 'b.example'; displayName = 'Tenant B' }
    $script:Partner = [pscustomobject]@{ customerId = $env:TenantID; defaultDomainName = 'partner.example'; displayName = 'Partner' }
    $script:SubA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:SubP = 'cccccccc-cccc-cccc-cccc-cccccccccccc'

    function New-PiOffer {
        param([string[]]$RoleIds, [string]$PrincipalId = $script:Principal.PrincipalId, [string]$ManagedBy = $env:TenantID)
        [pscustomobject]@{
            properties = [pscustomobject]@{
                registrationDefinition = [pscustomobject]@{
                    properties = [pscustomobject]@{
                        managedByTenantId          = $ManagedBy
                        registrationDefinitionName = 'Prometheus Informatik - CIPP AVD Management'
                        authorizations             = @($RoleIds | ForEach-Object { [pscustomobject]@{ principalId = $PrincipalId; roleDefinitionId = $_ } })
                    }
                }
            }
        }
    }

    function New-PiRequest {
        param([hashtable]$Query = @{})
        [pscustomobject]@{
            Body    = [pscustomobject]@{}
            Query   = [pscustomobject]$Query
            Params  = [pscustomobject]@{ CIPPEndpoint = 'Test' }
            Headers = @{}
        }
    }
}

Describe 'Get-PiLighthousePrincipal' {
    AfterEach { $env:PiAvdLighthousePrincipalId = $null }

    It 'prefers a configured group id over the SAM service principal' {
        $env:PiAvdLighthousePrincipalId = '66666666-6666-6666-6666-666666666666'
        Mock -CommandName New-GraphGetRequest -MockWith { throw 'must not be called' }
        $Result = Get-PiLighthousePrincipal
        $Result.PrincipalId | Should -Be '66666666-6666-6666-6666-666666666666'
        $Result.Source | Should -Be 'AppSetting'
    }

    It 'rejects a configured value that is not an object id' {
        $env:PiAvdLighthousePrincipalId = 'CIPP-SAM'
        { Get-PiLighthousePrincipal } | Should -Throw '*not a valid object id*'
    }

    It 'uses the service principal object id of the SAM app, not its client id' {
        Mock -CommandName New-GraphGetRequest -MockWith { @([pscustomobject]@{ id = $script:Principal.PrincipalId; displayName = 'CIPP-SAM'; appId = $env:ApplicationID }) }
        $Result = Get-PiLighthousePrincipal
        $Result.PrincipalId | Should -Be $script:Principal.PrincipalId
        Should -Invoke New-GraphGetRequest -Times 1 -ParameterFilter { $tenantid -eq $env:TenantID -and $uri -like "*appId eq '$($env:ApplicationID)'*" }
    }
}

Describe 'Get-PiLighthouseTemplate' {
    It 'bakes in the partner tenant and principal and delegates exactly the AVD module roles' {
        $Template = Get-PiLighthouseTemplate -ManagedByTenantId $env:TenantID -PrincipalId $script:Principal.PrincipalId
        $Template.parameters.managedByTenantId.defaultValue | Should -Be $env:TenantID
        $Template.parameters.cippPrincipalId.defaultValue | Should -Be $script:Principal.PrincipalId
        $Roles = @($Template.resources[0].properties.authorizations.roleDefinitionId)
        $Roles | Should -Be @((Get-PiLighthouseRoles).Id)
        $Template.resources[1].dependsOn[0] | Should -BeLike "*registrationDefinitions*"
    }

    It 'refuses ids that are not GUIDs' {
        { Get-PiLighthouseTemplate -ManagedByTenantId 'partner.example' -PrincipalId $script:Principal.PrincipalId } | Should -Throw '*not a valid id*'
    }

    It 'returns the template as JSON text from the endpoint' {
        Mock -CommandName Get-PiLighthousePrincipal -MockWith { $script:Principal }
        $Response = Invoke-ListPiAzureLighthouseTemplate -Request (New-PiRequest)
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        ($Response.Body.TemplateJson | ConvertFrom-Json).resources.Count | Should -Be 2
        $Response.Body.AzCli | Should -BeLike 'az deployment sub create*cipp-avd-lighthouse.json'
    }
}

Describe 'Get-PiAzureAccessStatus (Lighthouse)' {
    BeforeEach {
        Mock -CommandName Search-PiResourceGraph -MockWith {
            if ($Query -like '*resourcecontainers*') {
                @(
                    [pscustomobject]@{ subscriptionId = $script:SubA; name = 'A prod'; tenantId = $script:TenantA.customerId; state = 'Enabled' }
                    [pscustomobject]@{ subscriptionId = $script:SubP; name = 'Partner'; tenantId = $env:TenantID; state = 'Enabled' }
                )
            } else {
                @([pscustomobject]@{ subscriptionId = $script:SubA; HostPools = 2 })
            }
        }
    }

    It 'reports Full when the offer delegates all three roles to the configured principal' {
        Mock -CommandName Send-PiArmRequest -MockWith { @(New-PiOffer -RoleIds (Get-PiLighthouseRoles).Id) }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantA) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'Full'
        $Row.Access | Should -Be 'Lighthouse'
        $Row.HostPools | Should -Be 2
        $Row.MissingRoles | Should -Be ''
    }

    It 'reports ReadOnly when only Reader is delegated' {
        Mock -CommandName Send-PiArmRequest -MockWith { @(New-PiOffer -RoleIds @((Get-PiLighthouseRoles)[0].Id)) }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantA) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'ReadOnly'
        $Row.MissingRoles | Should -BeLike '*Session Host Operator*'
    }

    It 'flags offers that authorize another principal instead of guessing' {
        Mock -CommandName Send-PiArmRequest -MockWith { @(New-PiOffer -RoleIds (Get-PiLighthouseRoles).Id -PrincipalId '55555555-5555-5555-5555-555555555555') }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantA) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'OtherPrincipal'
        $Row.SubscriptionDetails[0].Note | Should -BeLike '*55555555-5555-5555-5555-555555555555*PiAvdLighthousePrincipalId*'
    }

    It 'ignores offers managed by another partner tenant' {
        Mock -CommandName Send-PiArmRequest -MockWith { @(New-PiOffer -RoleIds (Get-PiLighthouseRoles).Id -ManagedBy '44444444-4444-4444-4444-444444444444') }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantA) -Principal $script:Principal)[0]
        $Row.Status | Should -Not -Be 'Full'
        $Row.SubscriptionDetails[0].Note | Should -BeLike '*no Lighthouse offer from this partner tenant*'
    }

    It 'reports Unknown, not healthy, when the role lookup fails' {
        Mock -CommandName Send-PiArmRequest -MockWith { throw 'ARM GET failed (403 AuthorizationFailed)' }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantA) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'Unknown'
    }

    It 'reports NotOnboarded for a tenant without visible subscriptions' {
        Mock -CommandName Send-PiArmRequest -MockWith { throw 'must not be called' }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:TenantB) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'NotOnboarded'
        $Row.Subscriptions | Should -Be 0
    }

    It 'reads direct role assignments for the partner tenant''s own subscriptions' {
        Mock -CommandName Send-PiArmRequest -MockWith {
            @((Get-PiLighthouseRoles).Id | ForEach-Object { [pscustomobject]@{ properties = [pscustomobject]@{ roleDefinitionId = "/subscriptions/$($script:SubP)/providers/Microsoft.Authorization/roleDefinitions/$_" } } })
        }
        $Row = @(Get-PiAzureAccessStatus -Tenants @($script:Partner) -Principal $script:Principal)[0]
        $Row.Status | Should -Be 'Full'
        $Row.Access | Should -Be 'Direct RBAC'
        Should -Invoke Send-PiArmRequest -Times 1 -ParameterFilter { $Uri -like "*roleAssignments*assignedTo('$($script:Principal.PrincipalId)')*" }
    }
}

Describe 'Invoke-ListPiCloudPCs' {
    BeforeEach {
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName Resolve-PiAvdTenantScope -MockWith { @($script:TenantA) }
    }

    It 'derives health from status and connectivity and never calls an unconnected Cloud PC healthy' {
        Mock -CommandName New-GraphGetRequest -MockWith {
            @(
                [pscustomobject]@{ id = '1'; displayName = 'CPC-ok'; status = 'provisioned'; connectivityResult = [pscustomobject]@{ status = 'available' } }
                [pscustomobject]@{ id = '2'; displayName = 'CPC-nocheck'; status = 'provisioned' }
                [pscustomobject]@{ id = '3'; displayName = 'CPC-down'; status = 'provisioned'; connectivityResult = [pscustomobject]@{ status = 'unavailable' } }
                [pscustomobject]@{ id = '4'; displayName = 'CPC-failed'; status = 'failed' }
            )
        }
        $Response = Invoke-ListPiCloudPCs -Request (New-PiRequest -Query @{ tenantFilter = 'a.example' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Health = @{}
        foreach ($Row in $Response.Body) { $Health[$Row.Name] = $Row.Health }
        $Health['CPC-ok'] | Should -Be 'Healthy'
        $Health['CPC-nocheck'] | Should -Be 'Unknown'
        $Health['CPC-down'] | Should -Be 'Warning'
        $Health['CPC-failed'] | Should -Be 'Error'
    }

    It 'falls back to Intune Cloud PC devices and marks them limited when the Windows 365 API is denied' {
        Mock -CommandName New-GraphGetRequest -MockWith {
            if ($uri -like '*virtualEndpoint*') { throw 'Forbidden: CloudPC.Read.All' }
            @(
                [pscustomobject]@{ id = 'd1'; deviceName = 'CPC-anna'; model = 'Cloud PC Enterprise 2vCPU'; manufacturer = 'Microsoft Corporation' }
                [pscustomobject]@{ id = 'd2'; deviceName = 'LAPTOP-1'; model = 'Latitude'; manufacturer = 'Dell' }
            )
        }
        $Response = Invoke-ListPiCloudPCs -Request (New-PiRequest -Query @{ tenantFilter = 'a.example' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        @($Response.Body).Count | Should -Be 1
        $Response.Body[0].Source | Should -Be 'Intune (limited)'
        $Response.Body[0].Health | Should -Be 'Unknown'
    }

    It 'returns an error for a single tenant that cannot be read at all' {
        Mock -CommandName New-GraphGetRequest -MockWith { throw 'Forbidden' }
        $Response = Invoke-ListPiCloudPCs -Request (New-PiRequest -Query @{ tenantFilter = 'a.example' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::InternalServerError)
    }

    It 'keeps unreadable tenants visible as error rows in AllTenants' {
        Mock -CommandName Resolve-PiAvdTenantScope -MockWith { @($script:TenantA, $script:TenantB) }
        Mock -CommandName New-GraphGetRequest -MockWith {
            if ($tenantid -eq 'b.example') { throw 'Forbidden' }
            @([pscustomobject]@{ id = '1'; displayName = 'CPC-ok'; status = 'provisioned'; connectivityResult = [pscustomobject]@{ status = 'available' } })
        }
        $Response = Invoke-ListPiCloudPCs -Request (New-PiRequest -Query @{ tenantFilter = 'AllTenants' })
        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $ErrorRow = @($Response.Body | Where-Object Tenant -EQ 'b.example')
        $ErrorRow.Count | Should -Be 1
        $ErrorRow[0].Health | Should -Be 'Error'
    }
}
