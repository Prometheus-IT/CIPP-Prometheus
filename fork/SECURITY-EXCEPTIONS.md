# Temporary image-security exception

## Inherited Craft zlib finding

On 9 November 2026, the user requested that PR #12 be mergeable while keeping the upstream Craft runtime, after being informed of the zlib finding. This accepts the specific risk below temporarily; it does not patch the vulnerable package.

| Field | Accepted value |
| --- | --- |
| Vulnerability | CVE-2026-85091 |
| OS | Azure Linux 3.0 |
| Result class/type | `os-pkgs` / `azurelinux` |
| Package | `zlib` |
| Installed version | `1.3.2-1.azl3` |
| Reported fixed version | `1.3.2-2.azl3` |
| Severity | HIGH |
| Valid through | 23 November 2026, inclusive, UTC |

The observed source is CyberDrain's stable Craft 1.0.32 image, `ghcr.io/cyberdrain/craft:latest@sha256:46ccef61c16aeb966898c988bcfe02cbf859ea27e64286b3e45833b8270d8406`. The scanner reported a heap buffer overflow in zlib's `gz_vacate()` handling. This is inherited runtime content rather than a dependency introduced by the Azure reports.

The exception is matched in `.github/scripts/check_image_vulnerabilities.py` against all the fields above. A different vulnerability, package/version, OS, fixed version, or CRITICAL severity still blocks the gate. From 24 November onward, the unchanged finding blocks again. There is no automatic extension.

Trivy still scans the complete image. Its original report artifact retains the finding, and the CI log and job summary explicitly display the accepted risk and expiry. Invalid scans and every other fixable HIGH/CRITICAL finding continue to fail. Branch rules and required checks are unchanged.

Remove the exception once a patched upstream Craft base passes the full image scan, or review it explicitly before expiry if the upstream fix is still unavailable. No runtime rebuild or deployment is included in this exception.

Evidence: [completed scan with the inherited finding](https://github.com/Prometheus-IT/CIPP-Prometheus/actions/runs/42586504135).
