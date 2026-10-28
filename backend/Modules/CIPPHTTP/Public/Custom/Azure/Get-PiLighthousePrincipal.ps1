function Get-PiLighthousePrincipal {
    <#
    .SYNOPSIS
        Returns the partner-tenant principal that customer subscriptions should delegate to.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Lighthouse authorizations name a principal in
        the MANAGING tenant. Two supported designs:

          PiAvdLighthousePrincipalId app setting  Object id of a security group (or other
                                                  principal) that contains the CIPP SAM
                                                  service principal. Takes precedence.
          default                                 The CIPP SAM app's service principal, looked
                                                  up by $env:ApplicationID in $env:TenantID.

        The Object id of the enterprise application (service principal) is required. The
        application (client) id and the app registration's object id are different values and
        Lighthouse would silently authorize nobody.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param()

    $Parsed = [guid]::Empty
    $Configured = [System.Environment]::GetEnvironmentVariable('PiAvdLighthousePrincipalId')
    if (-not [string]::IsNullOrWhiteSpace($Configured)) {
        if (-not [guid]::TryParse($Configured, [ref]$Parsed)) {
            throw 'The PiAvdLighthousePrincipalId app setting is not a valid object id.'
        }
        return [pscustomobject]@{
            PrincipalId = $Parsed.ToString()
            DisplayName = 'Configured principal (PiAvdLighthousePrincipalId)'
            Source      = 'AppSetting'
        }
    }

    if (-not [guid]::TryParse([string]$env:ApplicationID, [ref]$Parsed)) {
        throw 'CIPP has no valid ApplicationID; the SAM application is not set up.'
    }
    # Validated GUID, safe to place in the filter.
    $Uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($Parsed.ToString())'&`$select=id,displayName,appId"
    $ServicePrincipal = @(New-GraphGetRequest -uri $Uri -tenantid $env:TenantID -NoAuthCheck $true) | Select-Object -First 1
    if (-not $ServicePrincipal.id) {
        throw "No service principal for the CIPP SAM application ($($Parsed.ToString())) was found in the partner tenant."
    }

    return [pscustomobject]@{
        PrincipalId = [string]$ServicePrincipal.id
        DisplayName = [string]$ServicePrincipal.displayName
        Source      = 'SamServicePrincipal'
    }
}
