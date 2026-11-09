# Azure retirements and change tracker

Two read-only pages under **Azure**:

- **Retirements** (`/custom/azure/retirements`): Azure Advisor service upgrade/retirement recommendations, affected resources, recommended actions, source state, dates where provided, tracking IDs and Microsoft guidance. Filter overdue, 0–30, 31–60, 61–90 days, later, or unknown deadlines. A resource's details link to its change history.
- **Change Tracker** (`/custom/azure/changes`): Resource Graph `resourcechanges` for the last 1, 7 or 14 days, with create/update/delete events, timestamps, actor, client, authorization operation, correlation ID and property differences. The optional `resourceId` URL parameter filters the returned events to that resource; **Show all resources** clears it.

Both pages use the existing CIPP customer selector, including AllTenants, and the standard searchable/exportable CIPP table. Refresh fetches a new report. Source coverage and retrieval time accompany the findings. Per-tenant errors remain visible even when other customers have results.

## Access and isolation

`ListPiAzureRetirements` and `ListPiAzureChanges` require `Endpoint.AzureReports.Read`. The existing built-in readonly/editor/admin roles include this read permission; custom roles need it explicitly. No consent, roles, app settings, Lighthouse templates, customer configuration or Azure resources are changed by these pages.

ARM authentication reuses `PiAvdArmAuthMode` and the existing token/request helpers. Reader access to the relevant subscription is sufficient for the intended Resource Graph reads; actual availability depends on customer delegation, Azure data and service support. GDAP alone does not grant Azure RBAC.

Every request resolves the caller's CIPP tenant scope first. Subscription ownership is discovered through `resourcecontainers`, filtered to those tenants, and used as the explicit query scope. Responses are filtered again by subscription and target resource ID. Tenant mode keeps each customer's token and results separate. Raw Azure errors are not returned to the browser.

## Data semantics and limits

- Retirement inventory starts from Advisor recommendations whose `extendedProperties.recommendationSubCategory` is `ServiceUpgradeAndRetirement`. Metadata is joined in memory by recommendation type; missing metadata does not discard recommendations. Dates come from `sourceProperties.serviceRetirement.retirementDate`, with the recommendation's explicit retirement date as fallback. A missing or invalid date stays unknown. UTC calendar dates determine deadline buckets. Upgrade recommendations without an explicit retirement date are retained as unknown.
- This page reads recommendations directly rather than treating all Service Health advisories as resource impact. It does not infer impact for unsupported retirements, execute metadata-provided queries, or mark recommendations completed based on their disappearance. Advisor state is displayed as supplied.
- Change history covers supported Azure resource **control-plane** changes only. It is not an audit of actions performed through CIPP and does not cover guest OS, data-plane activity, or a permanent history. Azure retains these records for 14 days. Deleted resources do not require a current resource inventory match. Create/delete events normally have no property differences. Missing actors, missing values, explicit nulls and truncated differences are distinguished.
- No visible subscriptions means **unknown access**, not “no Azure.” A successful empty query means no records returned in the visible scope, not comprehensive health. Failed or incomplete queries appear as unavailable. Metadata and findings have independent coverage.
- Queries page through continuation tokens with stable scalar IDs retained. A repeated token, 100-page safety limit, malformed envelope, or truncation without a token fails the source instead of presenting partial rows as complete. Explicit subscription scopes are batched at 1,000 IDs. Queries run on demand; no scheduled jobs or long-term storage are added.

## Packaging and verification

All source and tests live in the existing overlay roots, so the publisher includes them in its hash, preparation and triggers. `prometheus/pipeline.py` also checks both new frontend routes and endpoint references in the packaged artifact. The PR validation workflow runs the prepared backend and frontend tests before its existing non-publishing container build and security gate. The production publisher retains the existing tests and includes the new report suite.

Tests exercise tenant isolation, per-tenant failure, pagination/truncation, metadata failure, deadline boundaries, resource filtering, deleted resources, timestamps, before/after values, UI coverage, cache separation, tenant switching, links and read-only request contracts. They use fixtures and mocks: live Azure queries and customer coverage still need a post-deployment read-only acceptance check. A PR does not deploy the feature.

After an authorized deployment, check a known retirement and known change under a single tenant and AllTenants, a scoped user, an inaccessible tenant/source, unknown metadata, and the resource-specific history link. Confirm real source coverage before relying on an empty report.

Sources:

- [Microsoft retirement metadata and Resource Graph integration](https://learn.microsoft.com/en-us/azure/service-health/service-retirement-unified-impact-queries)
- [Resource Graph change queries and property semantics](https://learn.microsoft.com/en-us/azure/governance/resource-graph/changes/get-resource-changes)
- [Change Analysis scope and retention](https://learn.microsoft.com/en-us/azure/governance/resource-graph/changes/resource-graph-changes)
