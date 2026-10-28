function Get-PiAvdStandardInventory {
    <#
    .SYNOPSIS
        Collects the Azure resources the Prometheus AVD standards evaluate for one tenant.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Standards run in CIPP's background workers,
        which load CIPPStandards and CIPPCore but not CIPPHTTP, so this file cannot reuse the
        AVD module's HTTP helpers. It uses the same access model:

          PiAvdArmAuthMode = Lighthouse (default)  partner-tenant token, rows filtered to the
                                                   customer's tenant id
          PiAvdArmAuthMode = Tenant                token in the customer tenant

        Returns AzureAccess = 'NotDelegated' when no subscription of the tenant is visible.
        Callers must report that as non-compliant: a tenant CIPP cannot see is not a
        compliant tenant.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant
    )

    $TenantObject = @(Get-Tenants -TenantFilter $Tenant) | Select-Object -First 1
    $Parsed = [guid]::Empty
    if (-not $TenantObject -or -not [guid]::TryParse([string]$TenantObject.customerId, [ref]$Parsed)) {
        throw "Tenant '$Tenant' was not found in CIPP."
    }
    $TenantId = $Parsed.ToString()
    $Mode = if ([System.Environment]::GetEnvironmentVariable('PiAvdArmAuthMode') -eq 'Tenant') { 'Tenant' } else { 'Lighthouse' }
    $TokenTenant = if ($Mode -eq 'Tenant') { $TenantId } else { [string]$env:TenantID }

    # Validated GUID, safe to place in KQL.
    $Subscriptions = @(Search-PiAvdStandardResourceGraph -TokenTenant $TokenTenant -Query @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| where tenantId =~ '$TenantId'
| project subscriptionId, name
"@)

    $Inventory = [pscustomobject]@{
        TenantId        = $TenantId
        TokenTenant     = $TokenTenant
        AuthMode        = $Mode
        AzureAccess     = if ($Subscriptions.Count -gt 0) { 'Delegated' } else { 'NotDelegated' }
        Subscriptions   = $Subscriptions
        HostPools       = @()
        ScalingPlans    = @()
        StorageAccounts = @()
    }
    if ($Subscriptions.Count -eq 0) { return $Inventory }

    $Resources = @(Search-PiAvdStandardResourceGraph -TokenTenant $TokenTenant -Query @"
resources
| where tenantId =~ '$TenantId'
| where type in~ ('microsoft.desktopvirtualization/hostpools', 'microsoft.desktopvirtualization/scalingplans', 'microsoft.storage/storageaccounts')
| project id, name, type = tolower(type), subscriptionId, resourceGroup, location, kind, tags, properties
"@)
    $Inventory.HostPools = @($Resources | Where-Object type -EQ 'microsoft.desktopvirtualization/hostpools')
    $Inventory.ScalingPlans = @($Resources | Where-Object type -EQ 'microsoft.desktopvirtualization/scalingplans')
    $Inventory.StorageAccounts = @($Resources | Where-Object type -EQ 'microsoft.storage/storageaccounts')
    return $Inventory
}
