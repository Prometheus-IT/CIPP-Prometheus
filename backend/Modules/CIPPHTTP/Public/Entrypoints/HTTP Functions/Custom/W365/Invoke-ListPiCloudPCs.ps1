function Invoke-ListPiCloudPCs {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.CloudPC.Read
    .DESCRIPTION
        Fork addition. Read-only. Lists Windows 365 Cloud PCs for a tenant (or AllTenants) with provisioning status, connectivity health, licence plan and provisioning policy. Falls back to the Cloud PCs Intune knows about when the Windows 365 API is not consented, and marks those rows as limited.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Tenant domain, customerId or AllTenants.
    $TenantFilter = $Request.Query.tenantFilter

    $CloudPcSelect = @(
        'id', 'displayName', 'managedDeviceId', 'managedDeviceName', 'userPrincipalName', 'status',
        'servicePlanName', 'servicePlanType', 'productType', 'provisioningPolicyName', 'provisioningType',
        'imageDisplayName', 'onPremisesConnectionName', 'osVersion', 'powerState', 'connectivityResult',
        'lastLoginResult', 'lastModifiedDateTime', 'provisionedDateTime', 'gracePeriodEndDateTime', 'diskEncryptionState'
    ) -join ','
    $CloudPcUri = "https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs?`$select=$CloudPcSelect"
    $DeviceUri = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,userPrincipalName,model,manufacturer,deviceType,chassisType,osVersion,complianceState,lastSyncDateTime'

    # Health is derived only from what Windows 365 reports. Anything not explicitly good is not Healthy.
    $GetHealth = {
        param($Status, $Connectivity)
        if ($Status -in @('failed', 'resizePendingLicense')) { return 'Error' }
        if ($Status -eq 'provisioned') {
            if ($Connectivity -eq 'available') { return 'Healthy' }
            if ($Connectivity -eq 'unavailable') { return 'Warning' }
            return 'Unknown' # no health check result yet
        }
        if ($Status -in @('provisionedWithWarnings', 'inGracePeriod', 'pendingProvision')) { return 'Warning' }
        return 'Info' # transitional: provisioning, resizing, restoring, moving...
    }

    try {
        $Tenants = @(Resolve-PiAvdTenantScope -Request $Request -TenantFilter $TenantFilter)
        $Failures = [System.Collections.Generic.List[object]]::new()

        $Results = foreach ($Tenant in $Tenants) {
            $Domain = $Tenant.defaultDomainName
            try {
                $CloudPcs = New-GraphGetRequest -uri $CloudPcUri -tenantid $Domain -extraHeaders @{ Prefer = 'include-unknown-enum-members' }
                foreach ($CloudPc in @($CloudPcs)) {
                    if ($null -eq $CloudPc) { continue }
                    $Connectivity = [string]$CloudPc.connectivityResult.status
                    [pscustomobject]@{
                        Tenant                = $Domain
                        TenantName            = $Tenant.displayName
                        Name                  = $CloudPc.displayName
                        ManagedDeviceName     = $CloudPc.managedDeviceName
                        UserPrincipalName     = $CloudPc.userPrincipalName
                        Health                = & $GetHealth ([string]$CloudPc.status) $Connectivity
                        Status                = $CloudPc.status
                        Connectivity          = $Connectivity
                        ConnectivityCheckedAt = $CloudPc.connectivityResult.updatedDateTime
                        LastLogin             = $CloudPc.lastLoginResult.time
                        PowerState            = $CloudPc.powerState
                        ServicePlan           = $CloudPc.servicePlanName
                        ServicePlanType       = $CloudPc.servicePlanType
                        ProductType           = $CloudPc.productType
                        ProvisioningPolicy    = $CloudPc.provisioningPolicyName
                        ProvisioningType      = $CloudPc.provisioningType
                        Image                 = $CloudPc.imageDisplayName
                        Connection            = $CloudPc.onPremisesConnectionName
                        OsVersion             = $CloudPc.osVersion
                        DiskEncryption        = $CloudPc.diskEncryptionState
                        ProvisionedAt         = $CloudPc.provisionedDateTime
                        GracePeriodEnd        = $CloudPc.gracePeriodEndDateTime
                        LastModified          = $CloudPc.lastModifiedDateTime
                        ManagedDeviceId       = $CloudPc.managedDeviceId
                        Source                = 'Windows 365'
                        id                    = $CloudPc.id
                    }
                }
            } catch {
                $CloudPcError = $_.Exception.Message
                # Without CloudPC.Read.All consent, Intune still knows the Cloud PC devices.
                try {
                    $Devices = @(New-GraphGetRequest -uri $DeviceUri -tenantid $Domain | Where-Object { $_ -and (Test-CIPPCloudPCDevice -Device $_) })
                    foreach ($Device in $Devices) {
                        [pscustomobject]@{
                            Tenant            = $Domain
                            TenantName        = $Tenant.displayName
                            Name              = $Device.deviceName
                            ManagedDeviceName = $Device.deviceName
                            UserPrincipalName = $Device.userPrincipalName
                            Health            = 'Unknown'
                            Status            = 'Not available (Windows 365 API not readable)'
                            ServicePlan       = $Device.model
                            OsVersion         = $Device.osVersion
                            Compliance        = $Device.complianceState
                            LastSync          = $Device.lastSyncDateTime
                            ManagedDeviceId   = $Device.id
                            Source            = 'Intune (limited)'
                            SourceError       = $CloudPcError
                            id                = $Device.id
                        }
                    }
                    Write-LogMessage -headers $Headers -API $APIName -tenant $Domain -message "Windows 365 API unavailable, showing Intune Cloud PC devices only: $CloudPcError" -Sev 'Warning'
                } catch {
                    $Failures.Add([pscustomobject]@{ Tenant = $Tenant; Error = "Windows 365: $CloudPcError | Intune: $($_.Exception.Message)" })
                }
            }
        }

        foreach ($Failure in $Failures) {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Failure.Tenant.defaultDomainName -message "Cloud PC list failed: $($Failure.Error)" -Sev 'Error'
        }

        if ($TenantFilter -ne 'AllTenants' -and $Failures.Count -gt 0) {
            # A single tenant that could not be read is an error, never an empty list.
            throw $Failures[0].Error
        }

        # In AllTenants, unreadable tenants stay visible as explicit error rows.
        $ErrorRows = foreach ($Failure in $Failures) {
            [pscustomobject]@{
                Tenant      = $Failure.Tenant.defaultDomainName
                TenantName  = $Failure.Tenant.displayName
                Name        = '(tenant not readable)'
                Health      = 'Error'
                Status      = 'Error'
                Source      = 'Unavailable'
                SourceError = $Failure.Error
                id          = "error-$($Failure.Tenant.customerId)"
            }
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = @(@($Results) + @($ErrorRows) | Where-Object { $_ } | Sort-Object -Property Tenant, Name)
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to list Cloud PCs: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to list Cloud PCs: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
