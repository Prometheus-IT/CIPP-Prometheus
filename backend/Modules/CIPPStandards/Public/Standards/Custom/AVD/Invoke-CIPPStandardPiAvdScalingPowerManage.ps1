function Invoke-CIPPStandardPiAvdScalingPowerManage {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) PiAvdScalingPowerManage
    .SYNOPSIS
        (Label) AVD scaling plans only power-manage hosts (Prometheus)
    .DESCRIPTION
        (Helptext) Flags AVD scaling plans that use dynamic autoscale (CreateDeletePowerManage), which lets Azure create and delete session hosts. Optionally requires an enabled scaling plan on every pooled host pool. Report and alert only.
        (DocsDescription) Reads scaling plans and host pools through Azure Resource Graph (Azure Lighthouse or tenant RBAC, as configured for the CIPP AVD module). A schedule whose scalingMethod is CreateDeletePowerManage is non-compliant; schedules without a scalingMethod are power management only. Tenants whose subscriptions are not visible to CIPP are reported as non-compliant rather than compliant. This standard never changes Azure resources.
    .NOTES
        CAT
            Azure Virtual Desktop Standards
        TAG
        ADDEDCOMPONENT
            {"type":"switch","name":"standards.PiAvdScalingPowerManage.requireScalingPlan","label":"Also require an enabled scaling plan on every pooled host pool","defaultValue":false}
        DISABLEDFEATURES
            {"remediate":true}
        IMPACT
            Low Impact
        ADDEDDATE
            2026-10-28
        POWERSHELLEQUIVALENT
            Get-AzWvdScalingPlan
        RECOMMENDEDBY
            Prometheus
    .LINK
        https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan
    #>
    [CmdletBinding()]
    param($Tenant, $Settings)

    $StandardName = 'PiAvdScalingPowerManage'
    $RequirePlan = ($Settings.requireScalingPlan.value ?? $Settings.requireScalingPlan) -eq $true

    try {
        $Inventory = Get-PiAvdStandardInventory -Tenant $Tenant
        $CreateDelete = [System.Collections.Generic.List[string]]::new()
        $Unscaled = [System.Collections.Generic.List[string]]::new()
        $Findings = [System.Collections.Generic.List[string]]::new()

        if ($Inventory.AzureAccess -ne 'Delegated') {
            $Findings.Add('No Azure subscription of this tenant is visible to CIPP. Onboard it under Azure > Azure Lighthouse > Onboarding.')
        } else {
            $EnabledPools = @{}
            foreach ($Plan in $Inventory.ScalingPlans) {
                $Methods = @($Plan.properties.schedules | ForEach-Object { [string]$_.scalingMethod })
                if ($Methods -contains 'CreateDeletePowerManage') { $CreateDelete.Add([string]$Plan.name) }
                foreach ($Reference in @($Plan.properties.hostPoolReferences)) {
                    if ($Reference.scalingPlanEnabled -eq $true -and $Reference.hostPoolArmPath) {
                        $EnabledPools[([string]$Reference.hostPoolArmPath).ToLowerInvariant()] = $true
                    }
                }
            }
            if ($RequirePlan) {
                foreach ($Pool in $Inventory.HostPools | Where-Object { $_.properties.hostPoolType -eq 'Pooled' }) {
                    if (-not $EnabledPools[([string]$Pool.id).ToLowerInvariant()]) { $Unscaled.Add([string]$Pool.name) }
                }
            }
            if ($CreateDelete.Count -gt 0) {
                $Findings.Add("Scaling plan(s) $($CreateDelete -join ', ') use CreateDeletePowerManage and can create or delete session hosts.")
            }
            if ($Unscaled.Count -gt 0) {
                $Findings.Add("Pooled host pool(s) $($Unscaled -join ', ') have no enabled scaling plan.")
            }
        }

        Write-PiAvdStandardResult -Tenant $Tenant -StandardName $StandardName -Settings $Settings -Findings @($Findings) -CurrentValue @{
            AzureAccess                   = $Inventory.AzureAccess
            CreateDeleteScalingPlans      = @($CreateDelete | Sort-Object)
            PooledHostPoolsWithoutScaling = @($Unscaled | Sort-Object)
        } -ExpectedValue @{
            AzureAccess                   = 'Delegated'
            CreateDeleteScalingPlans      = @()
            PooledHostPoolsWithoutScaling = @()
        }
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Could not check AVD scaling plans. Error: $ErrorMessage" -sev Error
        throw
    }
}
