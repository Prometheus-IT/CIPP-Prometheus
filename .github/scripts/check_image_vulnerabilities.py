"""Fail closed on invalid scans and unaccepted fixable HIGH/CRITICAL findings."""

from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import sys


# User-approved exception for the inherited stable Craft runtime, documented in
# fork/SECURITY-EXCEPTIONS.md. Keep the finding in the report and job summary.
# Expiry is inclusive in UTC; no command-line switch can extend it.
UPSTREAM_ZLIB_ACCEPTED_FROM = date(2026, 11, 9)
UPSTREAM_ZLIB_ACCEPTED_UNTIL = date(2026, 11, 23)


def accepted_upstream_zlib(report, result, vulnerability, today):
    os_info = report.get('Metadata', {}).get('OS', {})
    return (
        UPSTREAM_ZLIB_ACCEPTED_FROM <= today <= UPSTREAM_ZLIB_ACCEPTED_UNTIL
        and os_info.get('Family') == 'azurelinux'
        and os_info.get('Name') == '3.0'
        and result.get('Class') == 'os-pkgs'
        and result.get('Type') == 'azurelinux'
        and vulnerability.get('VulnerabilityID') == 'CVE-2026-85091'
        and vulnerability.get('PkgName') == 'zlib'
        and vulnerability.get('InstalledVersion') == '1.3.2-1.azl3'
        and vulnerability.get('FixedVersion') == '1.3.2-2.azl3'
        and vulnerability.get('Severity') == 'HIGH'
    )


def evaluate(report, today=None):
    if not isinstance(report, dict) or report.get('SchemaVersion') != 2:
        raise ValueError('Expected a Trivy schema version 2 report')
    results = report.get('Results')
    if not isinstance(results, list) or not results:
        raise ValueError('Trivy report has no scanned results')
    today = today or datetime.now(timezone.utc).date()
    findings, blocked, accepted = [], [], []
    for result in results:
        if not isinstance(result, dict) or not result.get('Target'):
            raise ValueError('Invalid Trivy scan result')
        vulnerabilities = result.get('Vulnerabilities') or []
        if not isinstance(vulnerabilities, list):
            raise ValueError('Invalid vulnerability list')
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict) or not vulnerability.get('Severity'):
                raise ValueError('Invalid vulnerability finding')
            finding = (result['Target'], vulnerability)
            findings.append(finding)
            if vulnerability['Severity'] in ('HIGH', 'CRITICAL') and vulnerability.get('FixedVersion'):
                if accepted_upstream_zlib(report, result, vulnerability, today):
                    accepted.append(finding)
                else:
                    blocked.append(finding)
    return findings, blocked, accepted


def main(path):
    findings, blocked, accepted = evaluate(json.loads(Path(path).read_text(encoding='utf-8')))
    summary = (f'{len(findings)} findings; {len(blocked)} blocking (fixable HIGH/CRITICAL); '
               f'{len(accepted)} temporarily accepted upstream finding(s).')
    accepted_lines = [
        f'ACCEPTED through {UPSTREAM_ZLIB_ACCEPTED_UNTIL} UTC: {target}: '
        f"{v['VulnerabilityID']} {v['PkgName']} {v['InstalledVersion']} -> {v['FixedVersion']}. "
        'Inherited Craft runtime; user-approved merge exception, not a vulnerability fix. '
        'See fork/SECURITY-EXCEPTIONS.md.'
        for target, v in accepted
    ]
    print(summary)
    for line in accepted_lines:
        print(line)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as output:
            output.write(f'\n### Image security\n{summary}\n')
            for line in accepted_lines:
                output.write(f'\n{line}\n')
    for target, vulnerability in blocked:
        print(f"{target}: {vulnerability.get('VulnerabilityID')} "
              f"{vulnerability.get('PkgName')} {vulnerability.get('InstalledVersion')} "
              f"-> {vulnerability['FixedVersion']}")
    return 1 if blocked else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
