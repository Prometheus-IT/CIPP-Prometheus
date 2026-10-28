function Invoke-CIPPStandardPiAvdRdpProperties {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) PiAvdRdpProperties
    .SYNOPSIS
        (Label) AVD host pool RDP properties baseline (Prometheus)
    .DESCRIPTION
        (Helptext) Requires the listed RDP properties on AVD host pools, for example drive, clipboard or audio redirection. Remediate sets only the listed properties and keeps every other custom RDP property.
        (DocsDescription) Compares each host pool's customRdpProperty with the required name:type:value entries, separated by semicolons (for example drivestoredirect:s:;redirectclipboard:i:1;audiocapturemode:i:1). A property with the same name and type but another value is replaced; properties that are not listed are kept. Remediate sends a PATCH with only properties.customRdpProperty and reads the host pool back before reporting success; this needs hostpools/write, which the AVD module's Desktop Virtualization Power On Off Contributor delegation includes. New connections pick up the change; existing sessions keep their settings.
    .NOTES
        CAT
            Azure Virtual Desktop Standards
        TAG
        ADDEDCOMPONENT
            {"type":"textField","name":"standards.PiAvdRdpProperties.rdpProperties","label":"Required RDP properties (name:type:value, separated by ;)","required":true}
            {"type":"textField","name":"standards.PiAvdRdpProperties.hostPools","label":"Host pool names, comma separated (empty: every host pool)","required":false}
        IMPACT
            Medium Impact
        ADDEDDATE
            2026-10-28
        POWERSHELLEQUIVALENT
            Update-AzWvdHostPool -CustomRdpProperty
        RECOMMENDEDBY
            Prometheus
    .LINK
        https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties
    #>
    [CmdletBinding()]
    param($Tenant, $Settings)

    $StandardName = 'PiAvdRdpProperties'

    # name:type:value. The value may itself contain colons (URLs, paths).
    $ParseRdp = {
        param([string]$Text, [bool]$Strict)
        $Entries = [ordered]@{}
        foreach ($Raw in ($Text -split ';')) {
            $Entry = $Raw.Trim()
            if (-not $Entry) { continue }
            if ($Entry -notmatch '^(?<name>[A-Za-z0-9 _\-]+):(?<type>[isb]):(?<value>.*)$') {
                if ($Strict) { throw "'$Entry' is not a valid RDP property (expected name:type:value, type i, s or b); no Azure request was made." }
                continue
            }
            $Key = "$($Matches['name'].Trim().ToLowerInvariant()):$($Matches['type'].ToLowerInvariant())"
            $Entries[$Key] = "$($Matches['name'].Trim()):$($Matches['type']):$($Matches['value'])"
        }
        return $Entries
    }

    $Required = & $ParseRdp ([string]($Settings.rdpProperties.value ?? $Settings.rdpProperties)) $true
    if ($Required.Count -eq 0) {
        throw 'Enter at least one required RDP property before running this standard.'
    }
    $PoolFilter = @(([string]($Settings.hostPools.value ?? $Settings.hostPools)) -split '[,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })

    $Compare = {
        param($Pool)
        $Current = & $ParseRdp ([string]$Pool.properties.customRdpProperty) $false
        foreach ($Key in $Required.Keys) {
            if (-not $Current.Contains($Key)) { "$($Pool.name): $($Required[$Key]) missing" }
            elseif ($Current[$Key] -ne $Required[$Key]) { "$($Pool.name): $($Current[$Key]) instead of $($Required[$Key])" }
        }
    }

    try {
        $Inventory = Get-PiAvdStandardInventory -Tenant $Tenant
        $Versions = Get-PiAvdStandardApiVersion
        $Findings = [System.Collections.Generic.List[string]]::new()
        $OutOfBaseline = [System.Collections.Generic.List[string]]::new()

        if ($Inventory.AzureAccess -ne 'Delegated') {
            $Findings.Add('No Azure subscription of this tenant is visible to CIPP. Onboard it under Azure > Azure Lighthouse > Onboarding.')
        } else {
            $Pools = @($Inventory.HostPools | Where-Object { $PoolFilter.Count -eq 0 -or $PoolFilter -contains ([string]$_.name).ToLowerInvariant() })
            foreach ($Missing in $PoolFilter | Where-Object { $_ -notin @($Pools.name | ForEach-Object { ([string]$_).ToLowerInvariant() }) }) {
                $Findings.Add("${Missing}: host pool not found.")
                $OutOfBaseline.Add("$Missing (not found)")
            }

            foreach ($Pool in $Pools) {
                $Differences = @(& $Compare $Pool)
                if ($Differences.Count -eq 0) { continue }

                if ($Settings.remediate -eq $true) {
                    $Merged = & $ParseRdp ([string]$Pool.properties.customRdpProperty) $false
                    foreach ($Key in $Required.Keys) { $Merged[$Key] = $Required[$Key] }
                    $NewValue = (@($Merged.Values) -join ';') + ';'
                    $Uri = "https://management.azure.com$($Pool.id)?api-version=$($Versions.DesktopVirtualization)"
                    $null = Send-PiAvdStandardArmRequest -Uri $Uri -Method 'PATCH' -Body @{ properties = @{ customRdpProperty = $NewValue } } -TokenTenant $Inventory.TokenTenant
                    $ReadBack = Send-PiAvdStandardArmRequest -Uri $Uri -TokenTenant $Inventory.TokenTenant
                    $Differences = @(& $Compare $ReadBack)
                    if ($Differences.Count -gt 0) {
                        throw "Azure has not confirmed the RDP properties for host pool $($Pool.name): $($Differences -join '; ')"
                    }
                    Write-LogMessage -API 'Standards' -tenant $Tenant -message "AVD host pool $($Pool.name): RDP properties updated to the baseline." -sev Info
                    continue
                }

                $OutOfBaseline.Add([string]$Pool.name)
                foreach ($Difference in $Differences) { $Findings.Add("$Difference.") }
            }
        }

        Write-PiAvdStandardResult -Tenant $Tenant -StandardName $StandardName -Settings $Settings -Findings @($Findings) -CurrentValue @{
            AzureAccess            = $Inventory.AzureAccess
            HostPoolsOutOfBaseline = @($OutOfBaseline | Sort-Object)
        } -ExpectedValue @{
            AzureAccess            = 'Delegated'
            HostPoolsOutOfBaseline = @()
        }
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Could not check or set AVD RDP properties. Error: $ErrorMessage" -sev Error
        throw
    }
}
