function Invoke-CIPPStandardPiAvdStartVMOnConnect {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) PiAvdStartVMOnConnect
    .SYNOPSIS
        (Label) AVD Start VM on Connect is enabled (Prometheus)
    .DESCRIPTION
        (Helptext) Requires Start VM on Connect on every AVD host pool, and optionally checks that the Azure Virtual Desktop service has a power-on role on the subscriptions holding them. Remediate enables the host pool setting only; role assignments must be made by a customer administrator.
        (DocsDescription) Reads host pools through Azure Resource Graph. Remediate sends a PATCH with only properties.startVMOnConnect = true and reads the host pool back before reporting success; this needs hostpools/write, which the AVD module's Desktop Virtualization Power On Off Contributor delegation includes. The optional role check looks for a direct assignment of Desktop Virtualization Power On Contributor, Power On Off Contributor, Virtual Machine Contributor, Contributor or Owner to the Azure Virtual Desktop service principal (9cdead84-a844-4324-93f2-b2e6bb768d07). Without it, Start VM on Connect is enabled but cannot start VMs. Role lookups that fail are reported as non-compliant.
    .NOTES
        CAT
            Azure Virtual Desktop Standards
        TAG
        ADDEDCOMPONENT
            {"type":"switch","name":"standards.PiAvdStartVMOnConnect.checkPowerOnRole","label":"Also require a power-on role for the Azure Virtual Desktop service","defaultValue":true}
        IMPACT
            Low Impact
        ADDEDDATE
            2026-10-28
        POWERSHELLEQUIVALENT
            Update-AzWvdHostPool -StartVMOnConnect:$true
        RECOMMENDEDBY
            Prometheus
    .LINK
        https://learn.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect
    #>
    [CmdletBinding()]
    param($Tenant, $Settings)

    $StandardName = 'PiAvdStartVMOnConnect'
    $CheckRole = ($Settings.checkPowerOnRole.value ?? $Settings.checkPowerOnRole) -ne $false
    $AvdServiceAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
    $PowerOnRoleIds = @(
        '489581de-a3bd-480d-9518-53dea7416b33' # Desktop Virtualization Power On Contributor
        '40c5ff49-9181-41f8-ae61-143b0e78555e' # Desktop Virtualization Power On Off Contributor
        'a959dbd1-f747-45e3-8ba6-dd80f235f97c' # Desktop Virtualization Virtual Machine Contributor
        'b24988ac-6180-42a0-ab88-20f7382dd24c' # Contributor
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' # Owner
    )

    try {
        $Inventory = Get-PiAvdStandardInventory -Tenant $Tenant
        $Versions = Get-PiAvdStandardApiVersion
        $Findings = [System.Collections.Generic.List[string]]::new()
        $Disabled = @($Inventory.HostPools | Where-Object { $_.properties.startVMOnConnect -ne $true })
        $MissingRole = [System.Collections.Generic.List[string]]::new()

        if ($Inventory.AzureAccess -ne 'Delegated') {
            $Findings.Add('No Azure subscription of this tenant is visible to CIPP. Onboard it under Azure > Azure Lighthouse > Onboarding.')
        } else {
            if ($Settings.remediate -eq $true -and $Disabled.Count -gt 0) {
                foreach ($Pool in $Disabled) {
                    $Uri = "https://management.azure.com$($Pool.id)?api-version=$($Versions.DesktopVirtualization)"
                    $null = Send-PiAvdStandardArmRequest -Uri $Uri -Method 'PATCH' -Body @{ properties = @{ startVMOnConnect = $true } } -TokenTenant $Inventory.TokenTenant
                    $ReadBack = Send-PiAvdStandardArmRequest -Uri $Uri -TokenTenant $Inventory.TokenTenant
                    if ($ReadBack.properties.startVMOnConnect -ne $true) {
                        throw "Azure has not confirmed Start VM on Connect for host pool $($Pool.name)."
                    }
                    Write-LogMessage -API 'Standards' -tenant $Tenant -message "AVD host pool $($Pool.name): Start VM on Connect enabled." -sev Info
                }
                $Disabled = @()
            }

            if ($CheckRole -and $Inventory.HostPools.Count -gt 0) {
                $AvdService = $null
                try {
                    $AvdService = @(New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AvdServiceAppId'&`$select=id" -tenantid $Tenant) | Select-Object -First 1
                } catch {
                    $MissingRole.Add("Azure Virtual Desktop service principal lookup failed: $($_.Exception.Message)")
                }
                if ($AvdService -and -not $AvdService.id) { $AvdService = $null }
                if (-not $AvdService -and $MissingRole.Count -eq 0) {
                    $MissingRole.Add('The Azure Virtual Desktop service principal does not exist in this tenant.')
                }
                if ($AvdService) {
                    $Parsed = [guid]::Empty
                    if (-not [guid]::TryParse([string]$AvdService.id, [ref]$Parsed)) { throw 'Graph returned an invalid service principal id.' }
                    $PoolSubscriptions = @($Inventory.HostPools.subscriptionId | Sort-Object -Unique)
                    foreach ($SubscriptionId in $PoolSubscriptions) {
                        $SubscriptionGuid = [guid]::Empty
                        if (-not [guid]::TryParse([string]$SubscriptionId, [ref]$SubscriptionGuid)) { continue }
                        $SubscriptionId = $SubscriptionGuid.ToString()
                        $Name = ($Inventory.Subscriptions | Where-Object subscriptionId -EQ $SubscriptionId | Select-Object -First 1).name ?? $SubscriptionId
                        try {
                            $Uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments?api-version=$($Versions.Authorization)&`$filter=principalId eq '$($Parsed.ToString())'"
                            $Assigned = @(Send-PiAvdStandardArmRequest -Uri $Uri -TokenTenant $Inventory.TokenTenant -All |
                                    ForEach-Object { ([string]$_.properties.roleDefinitionId -split '/')[-1].ToLowerInvariant() })
                            if (-not @($Assigned | Where-Object { $_ -in $PowerOnRoleIds })) { $MissingRole.Add([string]$Name) }
                        } catch {
                            $MissingRole.Add("$Name (role lookup failed: $($_.Exception.Message))")
                        }
                    }
                }
            }

            if ($Disabled.Count -gt 0) {
                $Findings.Add("Start VM on Connect is off for host pool(s) $(@($Disabled.name) -join ', ').")
            }
            if ($MissingRole.Count -gt 0) {
                $Findings.Add("The Azure Virtual Desktop service has no power-on role for: $($MissingRole -join '; '). Start VM on Connect cannot start VMs there.")
            }
        }

        Write-PiAvdStandardResult -Tenant $Tenant -StandardName $StandardName -Settings $Settings -Findings @($Findings) -CurrentValue @{
            AzureAccess                       = $Inventory.AzureAccess
            HostPoolsWithoutStartVMOnConnect  = @($Disabled.name | Where-Object { $_ } | Sort-Object)
            SubscriptionsWithoutPowerOnRole   = @($MissingRole | Sort-Object)
        } -ExpectedValue @{
            AzureAccess                       = 'Delegated'
            HostPoolsWithoutStartVMOnConnect  = @()
            SubscriptionsWithoutPowerOnRole   = @()
        }
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Could not check or set AVD Start VM on Connect. Error: $ErrorMessage" -sev Error
        throw
    }
}
