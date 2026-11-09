function Get-PiAzureReport {
    <#
    .SYNOPSIS
        Reads tenant-scoped Azure retirement recommendations or resource changes.
    .DESCRIPTION
        Uses the existing AVD ARM authentication mode, but requires only Azure Reader access.
        Subscription ownership is established before reading report data. No request text or
        Advisor-provided query is executed as KQL. Coverage describes visible subscriptions only.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Tenants,
        [Parameter(Mandatory)] [ValidateSet('Retirements', 'Changes')] [string]$Kind,
        [ValidateSet(1, 7, 14)] [int]$Days = 7,
        [string]$ResourceId,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    # ConvertFrom-Json may already have converted ISO timestamps to DateTime objects.
    # Never round-trip those through a culture-dependent string before returning JSON.
    $ParseDate = {
        param($Value)
        if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
        if ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $Value = [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
            return ([datetimeoffset]$Value).ToUniversalTime()
        }
        $Parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$Parsed)) { return $Parsed.ToUniversalTime() }
        return $null
    }

    $SubscriptionQuery = @'
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project id, subscriptionId, tenantId, name
'@
    $RetirementQuery = @'
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where properties.extendedProperties.recommendationSubCategory == 'ServiceUpgradeAndRetirement'
| project id, subscriptionId, recommendationTypeId = tostring(properties.recommendationTypeId),
    resourceId = tostring(properties.resourceMetadata.resourceId),
    problem = tostring(properties.shortDescription.problem),
    solution = tostring(properties.shortDescription.solution),
    platformState = tostring(properties.platformState), lastUpdated = tostring(properties.lastUpdated),
    retirementDate = tostring(properties.extendedProperties.retirementDate)
'@
    $MetadataQuery = @'
advisorresources
| where type =~ 'microsoft.advisor/metadata'
| where properties.recommendationSubCategory == 'ServiceUpgradeAndRetirement'
| project id, recommendationTypeId = tostring(properties.recommendationTypeId),
    retirementDate = tostring(properties.sourceProperties.serviceRetirement.retirementDate),
    feature = tostring(properties.sourceProperties.serviceRetirement.retirementFeatureName),
    trackingIds = properties.sourceProperties.serviceRetirement.serviceHealth.trackingIds,
    learnMoreLink = tostring(properties.learnMoreLink)
'@
    # Days is a validated integer from a fixed set; resourceId is filtered after retrieval.
    $ChangesQuery = @"
resourcechanges
| extend changeTime = todatetime(properties.changeAttributes.timestamp)
| where changeTime > ago($($Days)d)
| project id, subscriptionId, changeTime, resourceId = tostring(properties.targetResourceId),
    resourceType = tostring(properties.targetResourceType), changeType = tostring(properties.changeType),
    changedBy = tostring(properties.changeAttributes.changedBy),
    changedByType = tostring(properties.changeAttributes.changedByType),
    clientType = tostring(properties.changeAttributes.clientType),
    operation = tostring(properties.changeAttributes.operation),
    correlationId = tostring(properties.changeAttributes.correlationId), changes = properties.changes
| order by changeTime desc, id asc
"@

    $Items = [System.Collections.Generic.List[object]]::new()
    $Coverage = [System.Collections.Generic.List[object]]::new()
    $Batches = if ((Get-PiAvdAuthMode) -eq 'Lighthouse') {
        @(@{ TokenTenant = $env:TenantID; Tenants = $Tenants })
    } else {
        @($Tenants | ForEach-Object { @{ TokenTenant = $_.customerId; Tenants = @($_) } })
    }
    foreach ($Batch in $Batches) {
        $Allowed = @{}
        foreach ($Tenant in $Batch.Tenants) { $Allowed[[string]$Tenant.customerId] = $Tenant }
        try {
            $Subscriptions = @(Search-PiAzureReportGraph -Query $SubscriptionQuery -TenantId $Batch.TokenTenant)
        } catch {
            foreach ($Tenant in $Batch.Tenants) {
                $Coverage.Add([pscustomobject]@{ Tenant = $Tenant.defaultDomainName; Source = 'Subscriptions'; Status = 'Unavailable'; Detail = 'Could not read subscription access. Check Azure permissions and retry.' })
            }
            continue
        }
        $BySubscription = @{}
        foreach ($Subscription in $Subscriptions) {
            $Tenant = $Allowed[[string]$Subscription.tenantId]
            $Guid = [guid]::Empty
            if ($Tenant -and [guid]::TryParse([string]$Subscription.subscriptionId, [ref]$Guid)) {
                $BySubscription[$Guid.ToString()] = @{ Tenant = $Tenant; Name = [string]$Subscription.name }
            }
        }
        foreach ($Tenant in $Batch.Tenants) {
            $Count = @($BySubscription.Values | Where-Object { $_.Tenant.customerId -eq $Tenant.customerId }).Count
            $Coverage.Add([pscustomobject]@{
                    Tenant = $Tenant.defaultDomainName; Source = 'Subscriptions'
                    Status = $(if ($Count) { 'Visible' } else { 'Unknown' })
                    Detail = $(if ($Count) { "$Count visible subscription(s); other subscriptions may be inaccessible." } else { 'No visible subscriptions. This does not establish that the customer has no Azure resources.' })
                })
        }
        if ($BySubscription.Count -eq 0) { continue }
        # ARG accepts at most 1,000 explicit subscriptions in a request.
        $Ids = @($BySubscription.Keys | Sort-Object)
        for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += 1000) {
            $Scope = @($Ids[$Offset..([math]::Min($Offset + 999, $Ids.Count - 1))])
            $ScopeTenants = @($Scope | ForEach-Object { $BySubscription[$_].Tenant } | Sort-Object customerId -Unique)
            $Metadata = @{}
            $MetadataAvailable = $true
            if ($Kind -eq 'Retirements') {
                try {
                    foreach ($Row in @(Search-PiAzureReportGraph -Query $MetadataQuery -TenantId $Batch.TokenTenant -Subscriptions $Scope)) {
                        if ($Row.recommendationTypeId) { $Metadata[[string]$Row.recommendationTypeId] = $Row }
                    }
                } catch { $MetadataAvailable = $false }
                foreach ($Tenant in $ScopeTenants) {
                    $Coverage.Add([pscustomobject]@{
                            Tenant = $Tenant.defaultDomainName; Source = 'Retirement metadata'
                            Status = $(if ($MetadataAvailable) { 'Retrieved' } else { 'Unavailable' })
                            Detail = $(if ($MetadataAvailable) { 'Azure metadata coverage is incomplete; dates and guidance can be unknown.' } else { 'Metadata could not be read. Recommendations remain visible with any dates supplied by Advisor.' })
                        })
                }
            }
            try {
                $Query = if ($Kind -eq 'Retirements') { $RetirementQuery } else { $ChangesQuery }
                $Rows = @(Search-PiAzureReportGraph -Query $Query -TenantId $Batch.TokenTenant -Subscriptions $Scope)
            } catch {
                foreach ($Tenant in $ScopeTenants) {
                    $Coverage.Add([pscustomobject]@{ Tenant = $Tenant.defaultDomainName; Source = $Kind; Status = 'Unavailable'; Detail = 'Query failed or was incomplete. Check Azure access and retry; an empty table does not mean no findings.' })
                }
                continue
            }
            foreach ($Tenant in $ScopeTenants) {
                $Coverage.Add([pscustomobject]@{ Tenant = $Tenant.defaultDomainName; Source = $Kind; Status = 'Retrieved'; Detail = 'Query completed for visible subscriptions. Azure data can be delayed or incomplete.' })
            }
            foreach ($Row in $Rows) {
                $SubscriptionId = [string]$Row.subscriptionId
                if ($SubscriptionId -notin $Scope) { continue }
                $Owner = $BySubscription[$SubscriptionId]
                $Target = [string]$Row.resourceId
                # Reject cross-subscription targets even if a response carries an allowed subscriptionId.
                if ($Target -and ($Target -notmatch '^/subscriptions/([0-9a-f-]{36})(/|$)' -or $Matches[1] -ne $SubscriptionId)) { continue }
                if ($ResourceId -and $Target.TrimEnd('/') -ine $ResourceId.TrimEnd('/')) { continue }
                $Item = [ordered]@{
                    id = [string]$Row.id; Tenant = $Owner.Tenant.defaultDomainName; TenantId = $Owner.Tenant.customerId
                    Subscription = $Owner.Name; SubscriptionId = $SubscriptionId
                    Resource = $(if ($Target) { ($Target.TrimEnd('/') -split '/')[-1] } else { 'Unknown resource' })
                    ResourceId = $Target
                }
                if ($Kind -eq 'Retirements') {
                    $Meta = $Metadata[[string]$Row.recommendationTypeId]
                    $RawDate = if ($Meta.retirementDate) { $Meta.retirementDate } else { $Row.retirementDate }
                    $Date = & $ParseDate $RawDate
                    $KnownDate = $null -ne $Date
                    $DaysRemaining = if ($KnownDate) { [int]($Date.UtcDateTime.Date - $Now.UtcDateTime.Date).TotalDays } else { $null }
                    $Item.Title = [string]$Row.problem
                    $Item.RequiredAction = [string]$Row.solution
                    $Item.Feature = [string]$Meta.feature
                    $Item.RetirementDate = if ($KnownDate) { $Date.ToUniversalTime().ToString('o') } else { $null }
                    $Item.DaysRemaining = $DaysRemaining
                    $Item.Deadline = if (-not $KnownDate) { 'Unknown' } elseif ($DaysRemaining -lt 0) { 'Overdue' } elseif ($DaysRemaining -le 30) { '0-30 days' } elseif ($DaysRemaining -le 60) { '31-60 days' } elseif ($DaysRemaining -le 90) { '61-90 days' } else { 'Later' }
                    $Item.AdvisorState = if ($Row.platformState) { [string]$Row.platformState } else { 'Unknown' }
                    $Item.TrackingIds = @($Meta.trackingIds) -join ', '
                    $Item.GuidanceUrl = [string]$Meta.learnMoreLink
                    $LastUpdated = & $ParseDate $Row.lastUpdated
                    $Item.LastUpdated = if ($LastUpdated) { $LastUpdated.ToString('o') } else { $null }
                } else {
                    $ChangeTime = & $ParseDate $Row.changeTime
                    $Item.ChangeTime = if ($ChangeTime) { $ChangeTime.ToString('o') } else { $null }
                    $Item.ChangeType = [string]$Row.changeType
                    $Item.ChangedBy = if ($Row.changedBy) { [string]$Row.changedBy } else { 'Unspecified' }
                    $Item.ActorType = [string]$Row.changedByType
                    $Item.Client = if ($Row.clientType) { [string]$Row.clientType } else { 'Unspecified' }
                    $Item.Operation = [string]$Row.operation
                    $Item.CorrelationId = [string]$Row.correlationId
                    $Item.ResourceType = [string]$Row.resourceType
                    $Changes = $Row.changes
                    if ($Changes -is [System.Collections.IDictionary]) { $Names = @($Changes.Keys) }
                    else { $Names = @($Changes.PSObject.Properties.Name) }
                    $Item.Changes = @($Names | Where-Object { $_ } | Sort-Object | ForEach-Object {
                            $Change = if ($Changes -is [System.Collections.IDictionary]) { $Changes[$_] } else { $Changes.$_ }
                            $Fields = if ($Change -is [System.Collections.IDictionary]) { @($Change.Keys) } else { @($Change.PSObject.Properties.Name) }
                            [pscustomobject]@{
                                Property = $_; Before = $Change.previousValue; After = $Change.newValue
                                BeforeProvided = 'previousValue' -in $Fields; AfterProvided = 'newValue' -in $Fields
                                Truncated = ([string]$Change.isTruncated -eq 'true')
                            }
                        })
                }
                $Items.Add([pscustomobject]$Item)
            }
        }
    }
    $Sorted = if ($Kind -eq 'Changes') { @($Items | Sort-Object ChangeTime -Descending) }
    else { @($Items | Sort-Object @{ Expression = { if ($null -eq $_.DaysRemaining) { [int]::MaxValue } else { $_.DaysRemaining } } }, Tenant, Resource) }
    [pscustomobject]@{ Items = $Sorted; Coverage = @($Coverage); RetrievedAt = $Now.ToUniversalTime().ToString('o'); LookbackDays = $(if ($Kind -eq 'Changes') { $Days } else { $null }) }
}
