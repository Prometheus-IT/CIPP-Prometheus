function Get-PiAvdAuthMode {
    <#
    .FUNCTIONALITY
        Internal
    #>
    $Mode = [System.Environment]::GetEnvironmentVariable('PiAvdArmAuthMode')
    if ($Mode -eq 'Tenant') { return 'Tenant' }
    return 'Lighthouse'
}
