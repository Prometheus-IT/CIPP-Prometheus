function Get-PiAvdStandardApiVersion {
    <#
    .SYNOPSIS
        ARM api-versions used by the Prometheus AVD standards.
    .DESCRIPTION
        Fork addition (Prometheus Informatik). Must match Get-PiAvdApiVersion in the AVD
        module (CIPPHTTP); prometheus/tests/test_pipeline.py checks that they agree.
    .FUNCTIONALITY
        Internal
    #>
    return @{
        DesktopVirtualization = '2025-10-10'
        Authorization         = '2022-04-01'
    }
}
