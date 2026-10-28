function Get-PiLighthouseRoles {
    <#
    .SYNOPSIS
        The Azure roles the CIPP AVD module asks customers to delegate, and what each one unlocks.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Single PowerShell source for the onboarding
        template and the onboarding status page. The role GUIDs must match
        fork/lighthouse/cipp-avd-lighthouse.bicep; prometheus/tests/test_pipeline.py fails the
        build when the two drift apart.
    .FUNCTIONALITY
        Internal
    #>
    return @(
        [pscustomobject]@{
            Name    = 'Reader'
            Id      = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
            Purpose = 'Host pool, session host, VM and storage inventory; AVD standards in report mode'
        }
        [pscustomobject]@{
            Name    = 'Desktop Virtualization Session Host Operator'
            Id      = '2ad6aaab-ead9-4eaa-8ac5-da422f562408'
            Purpose = 'Drain mode and session host management'
        }
        [pscustomobject]@{
            Name    = 'Desktop Virtualization Power On Off Contributor'
            Id      = '40c5ff49-9181-41f8-ae61-143b0e78555e'
            Purpose = 'Start and restart session host VMs, log off users, host pool settings (Start VM on Connect, RDP properties remediation)'
        }
    )
}
