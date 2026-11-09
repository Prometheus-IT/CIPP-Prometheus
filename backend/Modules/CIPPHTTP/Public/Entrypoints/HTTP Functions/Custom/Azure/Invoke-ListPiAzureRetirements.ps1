function Invoke-ListPiAzureRetirements {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.AzureReports.Read
    .DESCRIPTION
        Read-only Azure retirement recommendations, deadlines and coverage for the selected CIPP tenants.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    Get-PiAzureReportResponse -Request $Request -Kind Retirements
}
