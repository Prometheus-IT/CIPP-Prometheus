function Invoke-ListPiAvdUserSessions {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.Read
    .DESCRIPTION
        Fork addition. Lists active and disconnected Azure Virtual Desktop user sessions across host pools for a tenant (or AllTenants), optionally limited to one host pool.
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
            $Pools = @($Pools | Where-Object { $_.id -eq $HostPoolId })
        }

        $ApiVersion = (Get-PiAvdApiVersion).DesktopVirtualization

        $Results = foreach ($Pool in $Pools) {
            try {
                $Sessions = Send-PiArmRequest -Uri "https://management.azure.com$($Pool.id)/userSessions?api-version=$ApiVersion" -TenantId $Pool.tenantId -All
            } catch {
                $Warnings.Add([pscustomobject]@{ Tenant = $Pool.Tenant; Error = "Host pool $($Pool.name): $($_.Exception.Message)" })
                continue
            }

            foreach ($Session in @($Sessions)) {
                $Props = $Session.properties
                # name is <hostPool>/<sessionHost>/<sessionId>
                $NameParts = $Session.name -split '/'
                [pscustomobject]@{
                    Tenant                  = $Pool.Tenant
                    TenantName              = $Pool.TenantName
                    HostPool                = $Pool.name
                    HostPoolId              = $Pool.id
                    SessionHost             = if ($NameParts.Count -ge 3) { $NameParts[1] } else { $null }
                    SessionId               = $NameParts[-1]
                    UserPrincipalName       = $Props.userPrincipalName
                    ActiveDirectoryUserName = $Props.activeDirectoryUserName
                    SessionState            = $Props.sessionState
                    ApplicationType         = $Props.applicationType
                    CreateTime              = $Props.createTime
                    id                      = $Session.id
                }
            }
        }

        foreach ($Warning in $Warnings) {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Warning.Tenant -message "AVD user session query failed: $($Warning.Error)" -Sev 'Warning'
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = @($Results | Sort-Object -Property Tenant, HostPool, UserPrincipalName)
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to list AVD user sessions: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to list AVD user sessions: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
