function Get-PiAvdApiVersion {
    <#
    .SYNOPSIS
        Single place for the ARM api-versions this fork module uses.
    .DESCRIPTION
        DesktopVirtualization 2025-10-10 is the latest GA version at the time of writing.
        Bump here only; every AVD helper and endpoint reads from this function.
    .FUNCTIONALITY
        Internal
    #>
    return @{
        DesktopVirtualization = '2025-10-10'
        Compute               = '2024-07-01'
    }
}
