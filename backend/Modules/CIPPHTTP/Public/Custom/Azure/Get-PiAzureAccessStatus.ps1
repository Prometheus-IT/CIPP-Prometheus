function Get-PiAzureAccessStatus {
    <#
    .SYNOPSIS
        Reports, per CIPP tenant, which Azure subscriptions CIPP can reach and with which roles.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Read-only. Used by the Lighthouse onboarding
        page to replace the bare ARM 403 on the AVD pages with a per-customer answer.

        Lighthouse mode: one Resource Graph query from the partner tenant lists every visible
        subscription with its home tenant. For customer subscriptions the delegated roles come
        from the subscription's Lighthouse registration assignments (offers whose
        managedByTenantId is this partner tenant). For the partner tenant's own subscriptions
        they come from ordinary role assignments (direct RBAC).

        Tenant mode: the SAM app gets a token in each customer tenant; its roles come from
        role assignments of its service principal in that tenant.

        A subscription CIPP cannot see is indistinguishable from one that does not exist, so
        "NotOnboarded" means "no visible subscription", never "this customer has no Azure".
        Role lookups that fail are reported as Unknown, never as compliant.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tenants,

        # Output of Get-PiLighthousePrincipal (Lighthouse mode).
        $Principal
    )

    $RequiredRoles = @(Get-PiLighthouseRoles)
    $RoleNames = @{}
    foreach ($Role in $RequiredRoles) { $RoleNames[$Role.Id] = $Role.Name }
    $ReaderId = $RequiredRoles[0].Id
    $Mode = Get-PiAvdAuthMode
    $PartnerTenant = [string]$env:TenantID

    $GetRoleId = {
        param($Value)
        ([string]$Value -split '/')[-1].ToLowerInvariant()
    }

    $GetSubscriptionState = {
        param([string[]]$RoleIds, [bool]$Known, [bool]$OtherPrincipal)
        if (-not $Known) { return 'Unknown' }
        if ($OtherPrincipal -and $RoleIds.Count -eq 0) { return 'OtherPrincipal' }
        $Missing = @($RequiredRoles.Id | Where-Object { $_ -notin $RoleIds })
        if ($Missing.Count -eq 0) { return 'Full' }
        if ($RoleIds -contains $ReaderId -and $Missing.Count -eq ($RequiredRoles.Count - 1)) { return 'ReadOnly' }
        return 'Partial'
    }

    $GetRoleAssignmentIds = {
        # Role assignments for a principal, including inherited ones through groups.
        param([string]$SubscriptionId, [string]$PrincipalObjectId, [string]$TokenTenant)
        # assignedTo() includes group-inherited assignments but needs ARM to resolve group
        # membership; fall back to direct assignments when it cannot.
        $Base = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter="
        try {
            $Assignments = Send-PiArmRequest -Uri "$($Base)assignedTo('$PrincipalObjectId')" -TenantId $TokenTenant -All
        } catch {
            $Assignments = Send-PiArmRequest -Uri "$($Base)principalId eq '$PrincipalObjectId'" -TenantId $TokenTenant -All
        }
        @($Assignments | ForEach-Object { & $GetRoleId $_.properties.roleDefinitionId }) | Sort-Object -Unique
    }

    $Guid = [guid]::Empty
    $SubscriptionQuery = @'
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, name, tenantId, state = tostring(properties.state)
'@
    $HostPoolQuery = @'
resources
| where type =~ 'microsoft.desktopvirtualization/hostpools'
| summarize HostPools = count() by subscriptionId
'@

    $AllSubscriptions = @()
    $PoolCounts = @{}
    if ($Mode -eq 'Lighthouse') {
        if (-not $Principal -or -not [guid]::TryParse([string]$Principal.PrincipalId, [ref]$Guid)) {
            throw 'Lighthouse mode needs the delegated principal; run Get-PiLighthousePrincipal first.'
        }
        $AllSubscriptions = @(Search-PiResourceGraph -Query $SubscriptionQuery -TenantId $PartnerTenant)
        foreach ($Row in @(Search-PiResourceGraph -Query $HostPoolQuery -TenantId $PartnerTenant)) {
            $PoolCounts[([string]$Row.subscriptionId).ToLowerInvariant()] = [int]$Row.HostPools
        }
    }

    foreach ($Tenant in $Tenants) {
        $TenantId = [string]$Tenant.customerId
        $Details = [System.Collections.Generic.List[object]]::new()
        $TenantError = $null

        if ($Mode -eq 'Lighthouse') {
            $Subscriptions = @($AllSubscriptions | Where-Object { [string]$_.tenantId -eq $TenantId })
            foreach ($Subscription in $Subscriptions) {
                $SubscriptionId = [string]$Subscription.subscriptionId
                $RoleIds = @()
                $Known = $true
                $OtherPrincipal = $false
                $Offers = @()
                $Note = $null
                try {
                    if ($TenantId -eq $PartnerTenant) {
                        $Access = 'Direct RBAC'
                        $RoleIds = @(& $GetRoleAssignmentIds $SubscriptionId $Principal.PrincipalId $PartnerTenant)
                    } else {
                        $Access = 'Lighthouse'
                        $Uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.ManagedServices/registrationAssignments?api-version=2022-10-01&`$expandRegistrationDefinition=true"
                        $Assignments = @(Send-PiArmRequest -Uri $Uri -TenantId $PartnerTenant -All)
                        $Ours = @($Assignments | Where-Object {
                                [string]$_.properties.registrationDefinition.properties.managedByTenantId -eq $PartnerTenant
                            })
                        $Offers = @($Ours | ForEach-Object { [string]$_.properties.registrationDefinition.properties.registrationDefinitionName } | Sort-Object -Unique)
                        $Authorizations = @($Ours | ForEach-Object { $_.properties.registrationDefinition.properties.authorizations })
                        $RoleIds = @($Authorizations | Where-Object { [string]$_.principalId -eq $Principal.PrincipalId } |
                                ForEach-Object { & $GetRoleId $_.roleDefinitionId } | Sort-Object -Unique)
                        if ($RoleIds.Count -eq 0 -and $Authorizations.Count -gt 0) {
                            $OtherPrincipal = $true
                            $Others = @($Authorizations | ForEach-Object { [string]$_.principalId } | Sort-Object -Unique)
                            $Note = "Delegated to $($Others -join ', ') instead of $($Principal.PrincipalId). If that is a group containing the CIPP SAM service principal, set PiAvdLighthousePrincipalId to it."
                        } elseif ($Ours.Count -eq 0) {
                            $Note = 'Visible, but no Lighthouse offer from this partner tenant was found (access may come from another route).'
                        }
                    }
                } catch {
                    $Known = $false
                    $Note = "Role lookup failed: $($_.Exception.Message)"
                }

                $Details.Add([pscustomobject]@{
                        SubscriptionId = $SubscriptionId
                        Name           = [string]$Subscription.name
                        State          = [string]$Subscription.state
                        Access         = $Access
                        Status         = & $GetSubscriptionState $RoleIds $Known $OtherPrincipal
                        Roles          = (@($RoleIds | ForEach-Object { $RoleNames[$_] ?? $_ }) -join ', ')
                        Offers         = ($Offers -join ', ')
                        HostPools      = [int]($PoolCounts[$SubscriptionId.ToLowerInvariant()] ?? 0)
                        Note           = $Note
                    })
            }
        } else {
            try {
                if (-not [guid]::TryParse($TenantId, [ref]$Guid)) { throw 'Tenant has no valid customer id.' }
                $Subscriptions = @(Search-PiResourceGraph -Query $SubscriptionQuery -TenantId $TenantId)
                $Pools = @(Search-PiResourceGraph -Query $HostPoolQuery -TenantId $TenantId)
                $SamUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$([guid]::Parse([string]$env:ApplicationID).ToString())'&`$select=id"
                $SamInTenant = @(New-GraphGetRequest -uri $SamUri -tenantid $TenantId) | Select-Object -First 1
                foreach ($Subscription in $Subscriptions) {
                    $SubscriptionId = [string]$Subscription.subscriptionId
                    $RoleIds = @()
                    $Known = $true
                    $Note = $null
                    try {
                        if (-not [guid]::TryParse([string]$SamInTenant.id, [ref]$Guid)) { throw 'The CIPP SAM service principal was not found in this tenant.' }
                        $RoleIds = @(& $GetRoleAssignmentIds $SubscriptionId $SamInTenant.id $TenantId)
                    } catch {
                        $Known = $false
                        $Note = "Role lookup failed: $($_.Exception.Message)"
                    }
                    $PoolRow = $Pools | Where-Object { [string]$_.subscriptionId -eq $SubscriptionId } | Select-Object -First 1
                    $Details.Add([pscustomobject]@{
                            SubscriptionId = $SubscriptionId
                            Name           = [string]$Subscription.name
                            State          = [string]$Subscription.state
                            Access         = 'Tenant RBAC'
                            Status         = & $GetSubscriptionState $RoleIds $Known $false
                            Roles          = (@($RoleIds | ForEach-Object { $RoleNames[$_] ?? $_ }) -join ', ')
                            Offers         = ''
                            HostPools      = [int]($PoolRow.HostPools ?? 0)
                            Note           = $Note
                        })
                }
            } catch {
                $TenantError = $_.Exception.Message
            }
        }

        $States = @($Details.Status | Sort-Object -Unique)
        $Status = if ($TenantError) {
            'Unknown'
        } elseif ($Details.Count -eq 0) {
            'NotOnboarded'
        } elseif ($States -contains 'Unknown') {
            'Unknown'
        } elseif ($States.Count -eq 1) {
            $States[0]
        } else {
            'Partial'
        }

        $SplitRoles = { param($Text) @(([string]$Text -split ', ') | Where-Object { $_ }) }
        $PresentRoles = @($Details | ForEach-Object { & $SplitRoles $_.Roles } | Sort-Object -Unique)
        # A role counts as missing when any visible subscription lacks it.
        $MissingRoles = [System.Collections.Generic.List[string]]::new()
        if ($Details.Count -gt 0 -and $Status -notin @('Unknown', 'OtherPrincipal')) {
            foreach ($Role in $RequiredRoles) {
                foreach ($Item in $Details) {
                    if ((& $SplitRoles $Item.Roles) -notcontains $Role.Name) { $MissingRoles.Add($Role.Name); break }
                }
            }
        }

        $Detail = switch ($Status) {
            'Full' { 'All AVD module roles are delegated.' }
            'ReadOnly' { 'Read-only: inventory and report-mode standards work; drain, power and remediation actions will fail.' }
            'Partial' { "Some roles or subscriptions are missing: $($MissingRoles -join ', ')." }
            'OtherPrincipal' { 'Lighthouse offers exist but authorize a different principal; see subscription details.' }
            'NotOnboarded' {
                if ($Mode -eq 'Lighthouse') { 'No subscription of this tenant is delegated to CIPP. Deploy the onboarding template in each subscription with AVD.' }
                else { 'The CIPP SAM app sees no subscription in this tenant. Assign the AVD roles to its service principal.' }
            }
            default { if ($TenantError) { "Lookup failed: $TenantError" } else { 'At least one role lookup failed; see subscription details.' } }
        }

        [pscustomobject]@{
            Tenant                = $Tenant.defaultDomainName
            TenantName            = $Tenant.displayName
            TenantId              = $TenantId
            AuthMode              = $Mode
            Status                = $Status
            Detail                = $Detail
            Subscriptions         = $Details.Count
            SubscriptionsWithAvd  = @($Details | Where-Object { $_.HostPools -gt 0 }).Count
            HostPools             = [int](($Details | Measure-Object -Property HostPools -Sum).Sum ?? 0)
            Access                = (@($Details.Access | Sort-Object -Unique) -join ', ')
            Roles                 = ($PresentRoles -join ', ')
            MissingRoles          = ($MissingRoles -join ', ')
            SubscriptionDetails   = @($Details)
        }
    }
}
