# Prometheus CIPP overlay

Production image: `ghcr.io/prometheus-it/cipp-container:latest`. The image keeps this name after the repository rename to `CIPP-Prometheus`, so Azure continues following the same update source.

| File | Purpose |
| --- | --- |
| `Invoke-CIPPStandardPrometheusTeamsExternalChatFiles.ps1` | Custom Teams standard implementation. |
| `standards.json` | Portal label, help text and required Enabled/Disabled choice; added to both the frontend and backend standards catalogs. |
| `pipeline.py` | Resolve a stable CIPP release, apply the overlay and verify the built image. |
| `tests/` | Compatibility and policy behavior tests. |
| `build-state.json` | Last successful build and scheduled workflow activity; maintained by CI. |

## Updates

[The publisher](../.github/workflows/prometheus-container.yml) checks the latest official
stable release daily at 04:17 UTC. It builds that release's exact commit with this overlay,
runs both test suites and checks the packaged backend, portal and version metadata before
publishing a versioned image and updating `latest`. Failed checks leave `latest` unchanged.
CIPP's existing container updater follows the configured image repository.

Application versions use SemVer build metadata, for example `11.0.2+prometheus.<commit>.<hash>`.
CIPP considers that the same stable release as `11.0.2` while still warning about newer
official releases. Docker tags use `-prometheus` instead because image tags cannot contain
`+`; `build-state.json` records both. The updater compares complete version strings so it
also detects new custom builds of the same official release.

Overlay or workflow changes trigger a new build. `build-state.json` avoids unchanged
rebuilds and periodically records activity to keep GitHub's schedule enabled. Keep the
inherited container publishers disabled; preserve their files and the other CI workflows.
Use Actions and `build-state.json` for build provenance. Do not reset this overlay with
GitHub's **Sync fork** button.

## Standard and recovery

The standard controls only `FileSharingInChatsWithExternalUsers` on the assigned tenant's
Global Teams Files policy. Report reads only; Remediate applies the explicit Enabled or
Disabled choice and verifies the result. SharePoint and OneDrive restrictions still apply.
Assign tenant exceptions through the appropriate customer delta template.

`standards.json` also carries the four AVD standards (see [`fork/AVD.md`](../fork/AVD.md));
their implementations live in the AVD overlay folders. `pipeline.py` refuses to build when a
catalog entry has no implementation, and its tests check that each entry matches the
function's comment block. Adding another standard requires the implementation, the catalog
entry and its name in `AVD_STANDARDS` (or, for one copied from this folder, a `prepare` step).

The Azure additions (AVD module, Lighthouse onboarding page, Windows 365 Cloud PC view and
AVD standards) are also copied from the fork's dedicated folders into the released source.
Their source and tests are included in the overlay hash. The publisher runs the 49 fork
backend tests in `backend/Tests/Custom` and the portal tests, then verifies every compiled
fork function in CIPPHTTP and CIPPStandards, the five static portal pages and their API
endpoints before publishing. See
[`fork/AVD.md`](../fork/AVD.md) for customer Azure access requirements. The build does not
deploy Lighthouse or change customer permissions.

To roll back application code, pin Azure to a previously published version image. Saved
templates remain in Azure storage. Image rollback does not undo Microsoft 365 policy changes;
select Disabled and remediate separately to reverse this sharing setting.



## Defender dashboard current snapshot

`Invoke-ListDefenderDashboard.ps1` retains its existing `Security.DefenderDashboard.Read` role and tenant checks. A new GET-only `security` workload adds four independent sources: Defender AV health (`/api/deviceavinfo`), secure configuration assessments (`/api/machines/SecureConfigurationsAssessmentByMachine`), Graph XDR incidents (`/v1.0/security/incidents`), and the same beta Intune `managedDevices?$expand=windowsProtectionState` read used by CIPP's existing `ListDefenderState`, with a narrower projection. Only relevant evidence is returned; no recovery keys or user details are exported. Pagination must preserve the exact HTTPS origin and API path. Failed sources remain errors/forbidden, never successful empty lists.

This change does **not** modify consent, SAM grants, GDAP assignments, API clients/roles, tenant scope, other endpoints, the Teams standard, or the container workflow. It uses existing permissions only. Depending on current grants and licensing, individual sources can remain unavailable. Any additional consent needs a separate review and authorization. Required delegated read permissions are `Machine.Read` (AV JSON), `Vulnerability.Read` (assessments), `SecurityIncident.Read.All` (incidents), and `DeviceManagementManagedDevices.Read.All` (Intune), plus the corresponding workload/GDAP access. Beta Intune compatibility must be verified after deployment.

Deploy this overlay before the dashboard snapshot change. On the dashboard, verify each returned source and a known device in each tenant, including a denied source and a denied tenant. A deployment of this overlay uses the shared CIPP container and can restart its worker even though the source change is isolated; schedule the release accordingly. Do not infer live workload access from passing fixture tests. Rollback is the existing versioned-image procedure.
