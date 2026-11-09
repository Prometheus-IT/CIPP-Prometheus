function Invoke-ListPiAzureChanges {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AzureReports.Read
    .DESCRIPTION
        Read-only Azure control-plane changes with before/after values, actor and coverage for the selected CIPP tenants.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    Get-PiAzureReportResponse -Request $Request -Kind Changes
}
