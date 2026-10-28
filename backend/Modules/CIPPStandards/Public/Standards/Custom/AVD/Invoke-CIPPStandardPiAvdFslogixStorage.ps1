function Invoke-CIPPStandardPiAvdFslogixStorage {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) PiAvdFslogixStorage
    .SYNOPSIS
        (Label) AVD FSLogix storage accounts are hardened (Prometheus)
    .DESCRIPTION
        (Helptext) Checks the storage accounts holding FSLogix profiles: secure transfer required, minimum TLS 1.2, no anonymous blob access and, optionally, an approved private endpoint with public network access closed. Report and alert only.
        (DocsDescription) Reads storage accounts through Azure Resource Graph. Without a name list, the standard checks storage accounts in subscriptions that contain AVD host pools and that have identity-based Azure Files authentication (AD DS, Entra Kerberos or Entra Domain Services) or 'fslogix' in their name or tags. A tenant with pooled host pools but no detectable FSLogix storage is non-compliant until the account names are entered. The private endpoint check requires at least one approved private endpoint connection and either public network access disabled or a default-deny network rule. This standard never changes Azure resources.
    .NOTES
        CAT
            Azure Virtual Desktop Standards
        TAG
        ADDEDCOMPONENT
            {"type":"textField","name":"standards.PiAvdFslogixStorage.storageAccounts","label":"Storage account names, comma separated (empty: detect FSLogix accounts)","required":false}
            {"type":"switch","name":"standards.PiAvdFslogixStorage.requirePrivateEndpoint","label":"Require an approved private endpoint and closed public access","defaultValue":true}
        DISABLEDFEATURES
            {"remediate":true}
        IMPACT
            Low Impact
        ADDEDDATE
            2026-10-28
        POWERSHELLEQUIVALENT
            Get-AzStorageAccount
        RECOMMENDEDBY
            Prometheus
    .LINK
        https://learn.microsoft.com/en-us/azure/virtual-desktop/fslogix-profile-container-configure-azure-files-active-directory
    #>
    [CmdletBinding()]
    param($Tenant, $Settings)

    $StandardName = 'PiAvdFslogixStorage'
    $RequirePrivateEndpoint = ($Settings.requirePrivateEndpoint.value ?? $Settings.requirePrivateEndpoint) -ne $false
    $NameInput = [string]($Settings.storageAccounts.value ?? $Settings.storageAccounts)
    $RequestedNames = @($NameInput -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($Name in $RequestedNames) {
        if ($Name -notmatch '^[a-z0-9]{3,24}$') {
            throw "'$Name' is not a valid storage account name; no Azure request was made."
        }
    }

    try {
        $Inventory = Get-PiAvdStandardInventory -Tenant $Tenant
        $Findings = [System.Collections.Generic.List[string]]::new()
        $Checked = @()

        if ($Inventory.AzureAccess -ne 'Delegated') {
            $Findings.Add('No Azure subscription of this tenant is visible to CIPP. Onboard it under Azure > Azure Lighthouse > Onboarding.')
        } else {
            if ($RequestedNames.Count -gt 0) {
                $Checked = @($Inventory.StorageAccounts | Where-Object { $RequestedNames -contains ([string]$_.name).ToLowerInvariant() })
                foreach ($Missing in $RequestedNames | Where-Object { $_ -notin @($Checked.name | ForEach-Object { ([string]$_).ToLowerInvariant() }) }) {
                    $Findings.Add("${Missing}: not found in any visible subscription.")
                }
            } else {
                $AvdSubscriptions = @($Inventory.HostPools.subscriptionId | Sort-Object -Unique)
                $Checked = @($Inventory.StorageAccounts | Where-Object {
                        $_.subscriptionId -in $AvdSubscriptions -and (
                            [string]$_.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -in @('AD', 'AADKERB', 'AADDS') -or
                            [string]$_.name -match 'fslogix' -or
                            (@($_.tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';') -match 'fslogix'
                        )
                    })
                if ($Checked.Count -eq 0 -and @($Inventory.HostPools | Where-Object { $_.properties.hostPoolType -eq 'Pooled' }).Count -gt 0) {
                    $Findings.Add('Pooled host pools exist but no FSLogix storage account was detected. Enter the storage account names in this standard.')
                }
            }

            foreach ($Account in $Checked) {
                $Props = $Account.properties
                $Name = [string]$Account.name
                if ($Props.supportsHttpsTrafficOnly -ne $true) { $Findings.Add("${Name}: secure transfer is not required.") }
                if ([string]$Props.minimumTlsVersion -notin @('TLS1_2', 'TLS1_3')) { $Findings.Add("${Name}: minimum TLS version is $($Props.minimumTlsVersion ?? 'not set'), expected TLS1_2.") }
                if ($Props.allowBlobPublicAccess -eq $true) { $Findings.Add("${Name}: anonymous blob access is allowed.") }
                if ($RequirePrivateEndpoint) {
                    $Approved = @($Props.privateEndpointConnections | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' })
                    if ($Approved.Count -eq 0) { $Findings.Add("${Name}: no approved private endpoint.") }
                    if ([string]$Props.publicNetworkAccess -ne 'Disabled' -and [string]$Props.networkAcls.defaultAction -ne 'Deny') {
                        $Findings.Add("${Name}: public network access is open.")
                    }
                }
            }
        }

        Write-PiAvdStandardResult -Tenant $Tenant -StandardName $StandardName -Settings $Settings -Findings @($Findings) -CurrentValue @{
            AzureAccess     = $Inventory.AzureAccess
            StorageAccounts = @($Checked.name | Where-Object { $_ } | Sort-Object)
            Findings        = @($Findings | Sort-Object)
        } -ExpectedValue @{
            AzureAccess     = 'Delegated'
            StorageAccounts = @($Checked.name | Where-Object { $_ } | Sort-Object)
            Findings        = @()
        }
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Could not check AVD FSLogix storage. Error: $ErrorMessage" -sev Error
        throw
    }
}
