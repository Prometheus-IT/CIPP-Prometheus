"""Fail closed on invalid Trivy reports or fixable HIGH/CRITICAL findings."""

import json
import os
from pathlib import Path
import sys


def evaluate(report):
    if not isinstance(report, dict) or report.get('SchemaVersion') != 2:
        raise ValueError('Expected a Trivy schema version 2 report')
    results = report.get('Results')
    if not isinstance(results, list) or not results:
        raise ValueError('Trivy report has no scanned results')
    findings = []
    for result in results:
        if not isinstance(result, dict) or not result.get('Target'):
            raise ValueError('Invalid Trivy scan result')
        vulnerabilities = result.get('Vulnerabilities') or []
        if not isinstance(vulnerabilities, list):
            raise ValueError('Invalid vulnerability list')
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict) or not vulnerability.get('Severity'):
                raise ValueError('Invalid vulnerability finding')
            findings.append((result['Target'], vulnerability))
    blocked = [(target, v) for target, v in findings
               if v['Severity'] in ('HIGH', 'CRITICAL') and v.get('FixedVersion')]
    return findings, blocked


def main(path):
    findings, blocked = evaluate(json.loads(Path(path).read_text(encoding='utf-8')))
    summary = f'{len(findings)} findings; {len(blocked)} blocking (fixable HIGH/CRITICAL).'
    print(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as output:
            output.write(f'\n### Image security\n{summary}\n')
    for target, vulnerability in blocked:
        print(f"{target}: {vulnerability.get('VulnerabilityID')} "
              f"{vulnerability.get('PkgName')} {vulnerability.get('InstalledVersion')} "
              f"-> {vulnerability['FixedVersion']}")
    return 1 if blocked else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
