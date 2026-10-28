# Pester tests for the fork's AVD standards (Prometheus Informatik).
#
# Pins: tenants CIPP cannot see are non-compliant, report-only standards never write, and
# remediation sends only the intended property and confirms it before reporting success.

BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $HelperRoot = Join-Path $BackendRoot 'Modules/CIPPStandards/Public/Custom/AVD'
    $StandardRoot = Join-Path $BackendRoot 'Modules/CIPPStandards/Public/Standards/Custom/AVD'

    $env:TenantID = '99999999-9999-9999-9999-999999999999'
    $env:PiAvdArmAuthMode = $null

    # CIPP dependencies
    function Get-Tenants { param($TenantFilter) }
    function Get-GraphToken { param($tenantid, $scope, $AsApp) @{ Authorization = 'Bearer test' } }
    function Invoke-CIPPRestMethod { param($Uri, $Method, $Headers, $Body, $ContentType) }
    function New-GraphGetRequest { param($uri, $tenantid) }
    function Write-LogMessage { param($API, $tenant, $message, $sev) }
    function Write-StandardsAlert { param($message, $object, $tenant, $standardName, $standardId) }
    function Set-CIPPStandardsCompareField { param($FieldName, $TenantFilter, $CurrentValue, $ExpectedValue) }
    function Get-NormalizedError { param($Message) $Message }

    foreach ($File in Get-ChildItem -Path $HelperRoot -Filter '*.ps1') { . $File.FullName }
    foreach ($File in Get-ChildItem -Path $StandardRoot -Filter '*.ps1') { . $File.FullName }

    $script:TenantId = '11111111-1111-1111-1111-111111111111'
    $script:Sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:PoolId = "/subscriptions/$($script:Sub)/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp1"

    function New-PiInventory {
        param([object[]]$HostPools = @(), [object[]]$ScalingPlans = @(), [object[]]$StorageAccounts = @(), [string]$Access = 'Delegated')
        [pscustomobject]@{
            TenantId        = $script:TenantId
            TokenTenant     = $env:TenantID
            AuthMode        = 'Lighthouse'
            AzureAccess     = $Access
            Subscriptions   = if ($Access -eq 'Delegated') { @([pscustomobject]@{ subscriptionId = $script:Sub; name = 'A prod' }) } else { @() }
            HostPools       = $HostPools
            ScalingPlans    = $ScalingPlans
            StorageAccounts = $StorageAccounts
        }
    }

    function New-PiPool {
        param([string]$Name = 'hp1', [string]$Type = 'Pooled', $StartVM = $true, [string]$Rdp = '')
        [pscustomobject]@{
            id             = "/subscriptions/$($script:Sub)/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/$Name"
            name           = $Name
            subscriptionId = $script:Sub
            properties     = [pscustomobject]@{ hostPoolType = $Type; startVMOnConnect = $StartVM; customRdpProperty = $Rdp }
        }
    }
}

Describe 'Get-PiAvdStandardInventory' {
    It 'reports NotDelegated and stops when no subscription of the tenant is visible' {
        Mock -CommandName Get-Tenants -MockWith { @([pscustomobject]@{ customerId = $script:TenantId; defaultDomainName = 'a.example' }) }
        Mock -CommandName Search-PiAvdStandardResourceGraph -MockWith { @() }
        $Inventory = Get-PiAvdStandardInventory -Tenant 'a.example'
        $Inventory.AzureAccess | Should -Be 'NotDelegated'
        Should -Invoke Search-PiAvdStandardResourceGraph -Times 1 -Exactly
        Should -Invoke Search-PiAvdStandardResourceGraph -Times 1 -ParameterFilter { $TokenTenant -eq $env:TenantID -and $Query -like "*tenantId =~ '$($script:TenantId)'*" }
    }

    It 'refuses a tenant without a valid customer id before any Azure request' {
        Mock -CommandName Get-Tenants -MockWith { @([pscustomobject]@{ customerId = "x' or 1==1"; defaultDomainName = 'a.example' }) }
        Mock -CommandName Search-PiAvdStandardResourceGraph -MockWith { throw 'must not be called' }
        { Get-PiAvdStandardInventory -Tenant 'a.example' } | Should -Throw '*not found in CIPP*'
    }
}

Describe 'AVD standards with no Azure access' {
    BeforeEach {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { New-PiInventory -Access 'NotDelegated' }
        Mock -CommandName Set-CIPPStandardsCompareField -MockWith { }
        Mock -CommandName Write-StandardsAlert -MockWith { }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith { throw 'must not be called' }
    }

    It 'reports every AVD standard as non-compliant instead of compliant' {
        Invoke-CIPPStandardPiAvdScalingPowerManage -Tenant 'a.example' -Settings @{ report = $true }
        Invoke-CIPPStandardPiAvdStartVMOnConnect -Tenant 'a.example' -Settings @{ report = $true; remediate = $true }
        Invoke-CIPPStandardPiAvdFslogixStorage -Tenant 'a.example' -Settings @{ report = $true }
        Invoke-CIPPStandardPiAvdRdpProperties -Tenant 'a.example' -Settings @{ report = $true; remediate = $true; rdpProperties = 'drivestoredirect:s:' }
        Should -Invoke Set-CIPPStandardsCompareField -Times 4 -Exactly -ParameterFilter {
            $CurrentValue.AzureAccess -eq 'NotDelegated' -and $ExpectedValue.AzureAccess -eq 'Delegated'
        }
    }

    It 'alerts with a pointer to the onboarding page' {
        Invoke-CIPPStandardPiAvdScalingPowerManage -Tenant 'a.example' -Settings @{ alert = $true }
        Should -Invoke Write-StandardsAlert -Times 1 -ParameterFilter { $message -like '*Azure Lighthouse > Onboarding*' }
    }
}

Describe 'Invoke-CIPPStandardPiAvdScalingPowerManage' {
    BeforeEach {
        Mock -CommandName Set-CIPPStandardsCompareField -MockWith { }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith { throw 'report-only standard must not call ARM' }
    }

    It 'flags CreateDeletePowerManage schedules and pooled pools without an enabled plan' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith {
            New-PiInventory -HostPools @((New-PiPool -Name 'hp1'), (New-PiPool -Name 'hp2'), (New-PiPool -Name 'personal' -Type 'Personal')) -ScalingPlans @(
                [pscustomobject]@{ name = 'sp-dynamic'; properties = [pscustomobject]@{ schedules = @([pscustomobject]@{ scalingMethod = 'CreateDeletePowerManage' }); hostPoolReferences = @([pscustomobject]@{ hostPoolArmPath = (New-PiPool -Name 'hp1').id; scalingPlanEnabled = $true }) } }
                [pscustomobject]@{ name = 'sp-legacy'; properties = [pscustomobject]@{ schedules = @([pscustomobject]@{ name = 'weekdays' }); hostPoolReferences = @([pscustomobject]@{ hostPoolArmPath = (New-PiPool -Name 'hp2').id; scalingPlanEnabled = $false }) } }
            )
        }
        Invoke-CIPPStandardPiAvdScalingPowerManage -Tenant 'a.example' -Settings @{ report = $true; remediate = $true; requireScalingPlan = $true }
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter {
            ($CurrentValue.CreateDeleteScalingPlans -join ',') -eq 'sp-dynamic' -and ($CurrentValue.PooledHostPoolsWithoutScaling -join ',') -eq 'hp2'
        }
    }

    It 'treats schedules without a scaling method as power management only' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith {
            New-PiInventory -ScalingPlans @([pscustomobject]@{ name = 'sp'; properties = [pscustomobject]@{ schedules = @([pscustomobject]@{ name = 'weekdays' }) } })
        }
        Invoke-CIPPStandardPiAvdScalingPowerManage -Tenant 'a.example' -Settings @{ report = $true }
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { @($CurrentValue.CreateDeleteScalingPlans).Count -eq 0 }
    }
}

Describe 'Invoke-CIPPStandardPiAvdStartVMOnConnect' {
    BeforeEach {
        Mock -CommandName Set-CIPPStandardsCompareField -MockWith { }
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName New-GraphGetRequest -MockWith { @([pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333' }) }
        $script:PoolState = $false
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { New-PiInventory -HostPools @(New-PiPool -StartVM $false) }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith {
            if ($Uri -like '*roleAssignments*') {
                return @([pscustomobject]@{ properties = [pscustomobject]@{ roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/489581de-a3bd-480d-9518-53dea7416b33' } })
            }
            if ($Method -eq 'PATCH') { $script:Writes.Add($Body); $script:PoolState = $Body.properties.startVMOnConnect; return }
            [pscustomobject]@{ properties = [pscustomobject]@{ startVMOnConnect = $script:PoolState } }
        }
    }

    It 'does not write in report mode' {
        Invoke-CIPPStandardPiAvdStartVMOnConnect -Tenant 'a.example' -Settings @{ report = $true }
        $script:Writes.Count | Should -Be 0
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { ($CurrentValue.HostPoolsWithoutStartVMOnConnect -join ',') -eq 'hp1' }
    }

    It 'sends only startVMOnConnect and reports compliance after reading it back' {
        Invoke-CIPPStandardPiAvdStartVMOnConnect -Tenant 'a.example' -Settings @{ remediate = $true }
        $script:Writes.Count | Should -Be 1
        @($script:Writes[0].properties.Keys) | Should -Be @('startVMOnConnect')
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter {
            @($CurrentValue.HostPoolsWithoutStartVMOnConnect).Count -eq 0 -and @($CurrentValue.SubscriptionsWithoutPowerOnRole).Count -eq 0
        }
    }

    It 'fails when Azure does not confirm the change' {
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith {
            if ($Method -eq 'PATCH') { return }
            [pscustomobject]@{ properties = [pscustomobject]@{ startVMOnConnect = $false } }
        }
        { Invoke-CIPPStandardPiAvdStartVMOnConnect -Tenant 'a.example' -Settings @{ remediate = $true; checkPowerOnRole = $false } } | Should -Throw '*has not confirmed*'
        Should -Invoke Set-CIPPStandardsCompareField -Times 0 -Exactly
    }

    It 'reports a missing AVD service power-on role and a failed role lookup as non-compliant' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { New-PiInventory -HostPools @(New-PiPool -StartVM $true) }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith { throw 'ARM GET failed (403 AuthorizationFailed)' }
        Invoke-CIPPStandardPiAvdStartVMOnConnect -Tenant 'a.example' -Settings @{ report = $true }
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { ($CurrentValue.SubscriptionsWithoutPowerOnRole -join ',') -like 'A prod (role lookup failed*' }
    }
}

Describe 'Invoke-CIPPStandardPiAvdFslogixStorage' {
    BeforeEach {
        Mock -CommandName Set-CIPPStandardsCompareField -MockWith { }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith { throw 'report-only standard must not call ARM' }
    }

    It 'detects FSLogix accounts by identity-based Azure Files auth and reports each weakness' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith {
            New-PiInventory -HostPools @(New-PiPool) -StorageAccounts @(
                [pscustomobject]@{ name = 'camavdprofiles'; subscriptionId = $script:Sub; tags = $null; properties = [pscustomobject]@{
                        azureFilesIdentityBasedAuthentication = [pscustomobject]@{ directoryServiceOptions = 'AADKERB' }
                        supportsHttpsTrafficOnly = $false; minimumTlsVersion = 'TLS1_0'; allowBlobPublicAccess = $false
                        publicNetworkAccess = 'Enabled'; networkAcls = [pscustomobject]@{ defaultAction = 'Allow' }; privateEndpointConnections = @()
                    }
                }
                [pscustomobject]@{ name = 'diagstorage'; subscriptionId = $script:Sub; tags = $null; properties = [pscustomobject]@{ supportsHttpsTrafficOnly = $false } }
            )
        }
        Invoke-CIPPStandardPiAvdFslogixStorage -Tenant 'a.example' -Settings @{ report = $true }
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter {
            ($CurrentValue.StorageAccounts -join ',') -eq 'camavdprofiles' -and @($CurrentValue.Findings).Count -eq 4
        }
    }

    It 'is non-compliant when pooled host pools exist but no FSLogix storage is found' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { New-PiInventory -HostPools @(New-PiPool) }
        Invoke-CIPPStandardPiAvdFslogixStorage -Tenant 'a.example' -Settings @{ report = $true }
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { @($CurrentValue.Findings) -like '*no FSLogix storage account was detected*' }
    }

    It 'rejects invalid storage account names before any Azure request' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { throw 'must not be called' }
        { Invoke-CIPPStandardPiAvdFslogixStorage -Tenant 'a.example' -Settings @{ report = $true; storageAccounts = "good1,bad'name" } } | Should -Throw '*not a valid storage account name*'
    }
}

Describe 'Invoke-CIPPStandardPiAvdRdpProperties' {
    BeforeEach {
        Mock -CommandName Set-CIPPStandardsCompareField -MockWith { }
        Mock -CommandName Write-LogMessage -MockWith { }
        $script:Rdp = 'audiomode:i:0;drivestoredirect:s:*;'
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { New-PiInventory -HostPools @(New-PiPool -Rdp $script:Rdp) }
        Mock -CommandName Send-PiAvdStandardArmRequest -MockWith {
            if ($Method -eq 'PATCH') { $script:Writes.Add($Body); $script:Rdp = $Body.properties.customRdpProperty; return }
            New-PiPool -Rdp $script:Rdp
        }
    }

    It 'reports differences without writing in report mode' {
        Invoke-CIPPStandardPiAvdRdpProperties -Tenant 'a.example' -Settings @{ report = $true; rdpProperties = 'drivestoredirect:s:;redirectclipboard:i:0' }
        $script:Writes.Count | Should -Be 0
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { ($CurrentValue.HostPoolsOutOfBaseline -join ',') -eq 'hp1' }
    }

    It 'replaces listed properties, keeps the others and confirms the result' {
        Invoke-CIPPStandardPiAvdRdpProperties -Tenant 'a.example' -Settings @{ remediate = $true; rdpProperties = 'drivestoredirect:s:;redirectclipboard:i:0' }
        $script:Writes.Count | Should -Be 1
        @($script:Writes[0].properties.Keys) | Should -Be @('customRdpProperty')
        $script:Rdp | Should -Be 'audiomode:i:0;drivestoredirect:s:;redirectclipboard:i:0;'
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -ParameterFilter { @($CurrentValue.HostPoolsOutOfBaseline).Count -eq 0 }
    }

    It 'rejects malformed properties before any Azure request' {
        Mock -CommandName Get-PiAvdStandardInventory -MockWith { throw 'must not be called' }
        { Invoke-CIPPStandardPiAvdRdpProperties -Tenant 'a.example' -Settings @{ remediate = $true; rdpProperties = 'drivestoredirect=off' } } | Should -Throw '*not a valid RDP property*'
    }
}
