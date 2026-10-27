function Invoke-ListPiAvdSessionHosts {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.Read
    .DESCRIPTION
        Fork addition. Lists Azure Virtual Desktop session hosts with status, drain mode, session count and VM power state for a tenant (or AllTenants), optionally limited to one host pool.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain, customerId or AllTenants.
    $TenantFilter = $Request.Query.tenantFilter
    # Optional. Full ARM resource id of a host pool to limit the list to.
    $HostPoolId = $Request.Query.HostPoolId

    try {
        $Tenants = Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter
        $Warnings = [System.Collections.Generic.List[object]]::new()
        $Pools = @(Get-PiAvdHostPool -Tenants $Tenants -Warnings $Warnings)
        if (-not [string]::IsNullOrWhiteSpace($HostPoolId)) {
            # Filtering the in-scope pool list (rather than calling ARM with the raw id)
            # means a pool outside the user's tenants simply returns nothing.
            $Pools = @($Pools | Where-Object { $_.id -eq $HostPoolId })
        }

        $ApiVersion = (Get-PiAvdApiVersion).DesktopVirtualization
        $PowerStates = if ($Pools.Count -gt 0) { Get-PiAvdVmPowerState -Tenants $Tenants } else { @{} }

        $Results = foreach ($Pool in $Pools) {
            try {
                $SessionHosts = Send-PiArmRequest -Uri "https://management.azure.com$($Pool.id)/sessionHosts?api-version=$ApiVersion" -TenantId $Pool.tenantId -All
            } catch {
                $Warnings.Add([pscustomobject]@{ Tenant = $Pool.Tenant; Error = "Host pool $($Pool.name): $($_.Exception.Message)" })
                continue
            }

            foreach ($SessionHost in @($SessionHosts)) {
                $Props = $SessionHost.properties
                $VmId = [string]$Props.resourceId
                [pscustomobject]@{
                    Tenant          = $Pool.Tenant
                    TenantName      = $Pool.TenantName
                    HostPool        = $Pool.name
                    HostPoolId      = $Pool.id
                    ResourceGroup   = $Pool.resourceGroup
                    Name            = ($SessionHost.name -split '/')[-1]
                    Status          = $Props.status
                    AllowNewSession = [bool]$Props.allowNewSession
                    Sessions        = [int]$Props.sessions
                    AssignedUser    = $Props.assignedUser
                    PowerState      = if ($VmId) { $PowerStates[$VmId.ToLowerInvariant()] } else { $null }
                    UpdateState     = $Props.updateState
                    AgentVersion    = $Props.agentVersion
                    OsVersion       = $Props.osVersion
                    LastHeartBeat   = $Props.lastHeartBeat
                    VmResourceId    = $VmId
                    id              = $SessionHost.id
                }
            }
        }

        foreach ($Warning in $Warnings) {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Warning.Tenant -message "AVD session host query failed: $($Warning.Error)" -Sev 'Warning'
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = @($Results | Sort-Object -Property Tenant, HostPool, Name)
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to list AVD session hosts: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to list AVD session hosts: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
