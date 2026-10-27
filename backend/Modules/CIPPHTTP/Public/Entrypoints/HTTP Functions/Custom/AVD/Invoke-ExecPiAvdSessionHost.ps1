function Invoke-ExecPiAvdSessionHost {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.ReadWrite
    .DESCRIPTION
        Fork addition. Turns drain mode on or off for an Azure Virtual Desktop session host, or starts or restarts its virtual machine. Restart refuses hosts with sessions unless Force is set.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain or customerId that owns the session host. AllTenants is not accepted.
    $TenantFilter = $Request.Body.tenantFilter
    # Full ARM resource id of the session host.
    $SessionHostId = [string]$Request.Body.ID
    # drainOn, drainOff, start or restart
    $Action = [string]$Request.Body.Action
    # Optional. Restart even when users are signed in.
    $Force = $Request.Body.Force -eq $true

    $HostPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.DesktopVirtualization/hostPools/[^/]+/sessionHosts/[^/]+$'
    $VmPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+$'

    try {
        if ($TenantFilter -eq 'AllTenants' -or [string]::IsNullOrWhiteSpace($TenantFilter)) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'Select a single tenant for session host actions.' } })
        }
        if ($SessionHostId -notmatch $HostPattern) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'ID must be the full resource id of an AVD session host.' } })
        }
        if ($Action -notin @('drainOn', 'drainOff', 'start', 'restart')) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'Action must be drainOn, drainOff, start or restart.' } })
        }

        $Tenant = @(Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter)[0]
        Assert-PiAvdResourceTenant -ResourceId $SessionHostId -TenantId $Tenant.customerId

        $Versions = Get-PiAvdApiVersion
        $HostUri = "https://management.azure.com$($SessionHostId)?api-version=$($Versions.DesktopVirtualization)"
        $HostName = ($SessionHostId -split '/')[-1]

        switch ($Action) {
            { $_ -in @('drainOn', 'drainOff') } {
                $AllowNew = $Action -eq 'drainOff'
                $Payload = @{ properties = @{ allowNewSession = $AllowNew } }
                $null = Send-PiArmRequest -Uri $HostUri -Method 'PATCH' -Body $Payload -TenantId $Tenant.customerId
                $Message = if ($AllowNew) { "Drain mode off for $HostName (accepting new sessions)" } else { "Drain mode on for $HostName (no new sessions)" }
            }
            { $_ -in @('start', 'restart') } {
                $SessionHost = Send-PiArmRequest -Uri $HostUri -TenantId $Tenant.customerId
                $VmId = [string]$SessionHost.properties.resourceId
                if ($VmId -notmatch $VmPattern) {
                    throw "Session host $HostName has no linked Azure VM (resourceId '$VmId')."
                }
                Assert-PiAvdResourceTenant -ResourceId $VmId -TenantId $Tenant.customerId

                $SessionCount = [int]$SessionHost.properties.sessions
                if ($Action -eq 'restart' -and $SessionCount -gt 0 -and -not $Force) {
                    return ([HttpResponseContext]@{
                            StatusCode = [HttpStatusCode]::Conflict
                            Body       = @{ Results = "$HostName has $SessionCount session(s). Turn on drain mode and log users off, or use Force." }
                        })
                }

                $Operation = $Action # 'start' and 'restart' are the Compute action names
                $null = Send-PiArmRequest -Uri "https://management.azure.com$VmId/$($Operation)?api-version=$($Versions.Compute)" -Method 'POST' -TenantId $Tenant.customerId
                $Message = if ($Action -eq 'start') { "Start requested for $HostName" } else { "Restart requested for $HostName ($SessionCount session(s) at request time)" }
            }
        }

        Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "AVD: $Message" -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
        $Results = $Message
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "AVD session host action '$Action' failed: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Results = "AVD session host action '$Action' failed: $($ErrorMessage.NormalizedError)"
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Results }
        })
}
