function Invoke-ExecPiAvdUserSession {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AVD.ReadWrite
    .DESCRIPTION
        Fork addition. Logs off, disconnects or sends a message to an Azure Virtual Desktop user session.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain or customerId that owns the session. AllTenants is not accepted.
    $TenantFilter = $Request.Body.tenantFilter
    # Full ARM resource id of the user session.
    $SessionId = [string]$Request.Body.ID
    # logoff, disconnect or sendMessage
    $Action = [string]$Request.Body.Action
    # Optional. Used only in log and result messages.
    $UserPrincipalName = [string]$Request.Body.UserPrincipalName
    # Required for sendMessage.
    $MessageTitle = [string]$Request.Body.MessageTitle
    # Required for sendMessage.
    $MessageBody = [string]$Request.Body.MessageBody

    $SessionPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.DesktopVirtualization/hostPools/[^/]+/sessionHosts/[^/]+/userSessions/[^/]+$'

    try {
        if ($TenantFilter -eq 'AllTenants' -or [string]::IsNullOrWhiteSpace($TenantFilter)) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'Select a single tenant for session actions.' } })
        }
        if ($SessionId -notmatch $SessionPattern) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'ID must be the full resource id of an AVD user session.' } })
        }
        if ($Action -notin @('logoff', 'disconnect', 'sendMessage')) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'Action must be logoff, disconnect or sendMessage.' } })
        }
        if ($Action -eq 'sendMessage' -and ([string]::IsNullOrWhiteSpace($MessageTitle) -or [string]::IsNullOrWhiteSpace($MessageBody))) {
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ Results = 'sendMessage needs MessageTitle and MessageBody.' } })
        }

        $Tenant = @(Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter)[0]
        Assert-PiAvdResourceTenant -ResourceId $SessionId -TenantId $Tenant.customerId

        $ApiVersion = (Get-PiAvdApiVersion).DesktopVirtualization
        $BaseUri = "https://management.azure.com$SessionId"
        $Who = if ($UserPrincipalName) { $UserPrincipalName } else { ($SessionId -split '/')[-1] }
        $SessionHost = ($SessionId -split '/')[-3]

        switch ($Action) {
            'logoff' {
                $null = Send-PiArmRequest -Uri "$($BaseUri)?api-version=$ApiVersion&force=true" -Method 'DELETE' -TenantId $Tenant.customerId
                $Message = "Logged off $Who from $SessionHost"
            }
            'disconnect' {
                $null = Send-PiArmRequest -Uri "$BaseUri/disconnect?api-version=$ApiVersion" -Method 'POST' -TenantId $Tenant.customerId
                $Message = "Disconnected $Who from $SessionHost"
            }
            'sendMessage' {
                $Payload = @{ messageTitle = $MessageTitle; messageBody = $MessageBody }
                $null = Send-PiArmRequest -Uri "$BaseUri/sendMessage?api-version=$ApiVersion" -Method 'POST' -Body $Payload -TenantId $Tenant.customerId
                $Message = "Sent message to $Who on $SessionHost"
            }
        }

        Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "AVD: $Message" -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
        $Results = $Message
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "AVD session action '$Action' failed: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Results = "AVD session action '$Action' failed: $($ErrorMessage.NormalizedError)"
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Results }
        })
}
