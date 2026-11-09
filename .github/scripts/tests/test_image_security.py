import importlib.util
from copy import deepcopy
from datetime import date
from unittest.mock import patch
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_image_vulnerabilities.py'
spec = importlib.util.spec_from_file_location('image_security', SCRIPT)
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


def report(vulnerabilities):
    return {'SchemaVersion': 2, 'Results': [
        {'Target': 'candidate', 'Vulnerabilities': vulnerabilities}]}


def upstream_zlib_report():
    data = report([{
        'VulnerabilityID': 'CVE-2026-85091', 'PkgName': 'zlib',
        'InstalledVersion': '1.3.2-1.azl3', 'FixedVersion': '1.3.2-2.azl3',
        'Severity': 'HIGH',
    }])
    data['Metadata'] = {'OS': {'Family': 'azurelinux', 'Name': '3.0'}}
    data['Results'][0].update(Class='os-pkgs', Type='azurelinux')
    return data


class ImageSecurityTests(unittest.TestCase):
    def test_blocks_high_and_critical_with_fixes_across_results(self):
        data = report([{'Severity': 'HIGH', 'FixedVersion': '2.0'}])
        data['Results'].append({'Target': 'library', 'Vulnerabilities': [
            {'Severity': 'CRITICAL', 'FixedVersion': '3.0'}]})
        findings, blocked, accepted = security.evaluate(data)
        self.assertEqual(len(findings), 2)
        self.assertEqual(len(blocked), 2)
        self.assertEqual(accepted, [])

    def test_retains_unfixed_and_lower_severity_without_blocking(self):
        findings, blocked, accepted = security.evaluate(report([
            {'Severity': 'CRITICAL'}, {'Severity': 'HIGH', 'FixedVersion': ''},
            {'Severity': 'MEDIUM', 'FixedVersion': '2.0'}, {'Severity': 'UNKNOWN'}]))
        self.assertEqual(len(findings), 4)
        self.assertEqual(blocked, [])
        self.assertEqual(accepted, [])

    def test_accepts_clean_scanned_result(self):
        self.assertEqual(security.evaluate(report(None)), ([], [], []))

    def test_accepts_only_exact_upstream_finding_during_approved_window(self):
        for today in (date(2026, 11, 9), date(2026, 11, 23)):
            findings, blocked, accepted = security.evaluate(upstream_zlib_report(), today)
            self.assertEqual(len(findings), 1)
            self.assertEqual(blocked, [])
            self.assertEqual(accepted, findings)

    def test_expired_or_not_yet_active_exception_blocks(self):
        for today in (date(2026, 11, 8), date(2026, 11, 24), date(2027, 1, 1)):
            findings, blocked, accepted = security.evaluate(upstream_zlib_report(), today)
            self.assertEqual(blocked, findings)
            self.assertEqual(accepted, [])

    def test_other_cves_versions_packages_and_critical_severity_still_block(self):
        for field, value in (
            ('VulnerabilityID', 'CVE-2026-OTHER'), ('PkgName', 'another-package'),
            ('InstalledVersion', '1.3.1-1.azl3'), ('FixedVersion', '1.3.2-3.azl3'),
            ('Severity', 'CRITICAL'),
        ):
            data = upstream_zlib_report()
            data['Results'][0]['Vulnerabilities'][0][field] = value
            with self.subTest(field=field):
                findings, blocked, accepted = security.evaluate(data, date(2026, 11, 9))
                self.assertEqual(blocked, findings)
                self.assertEqual(accepted, [])

    def test_different_or_missing_os_context_still_blocks(self):
        original = upstream_zlib_report()
        variants = []
        for field, value in (('Class', 'lang-pkgs'), ('Type', 'debian')):
            data = deepcopy(original)
            data['Results'][0][field] = value
            variants.append(data)
        for field, value in (('Family', 'debian'), ('Name', '4.0')):
            data = deepcopy(original)
            data['Metadata']['OS'][field] = value
            variants.append(data)
        data = deepcopy(original)
        del data['Metadata']
        variants.append(data)
        for data in variants:
            findings, blocked, accepted = security.evaluate(data, date(2026, 11, 9))
            self.assertEqual(blocked, findings)
            self.assertEqual(accepted, [])

    def test_accepted_finding_does_not_hide_another_blocker(self):
        data = upstream_zlib_report()
        data['Results'][0]['Vulnerabilities'].append({
            'Severity': 'CRITICAL', 'FixedVersion': '2.0', 'VulnerabilityID': 'OTHER',
        })
        findings, blocked, accepted = security.evaluate(data, date(2026, 11, 9))
        self.assertEqual(len(findings), 2)
        self.assertEqual(len(accepted), 1)
        self.assertEqual(len(blocked), 1)
        self.assertEqual(blocked[0][1]['VulnerabilityID'], 'OTHER')

    def test_job_summary_keeps_the_accepted_risk_and_expiry_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'report.json'
            summary = Path(temporary) / 'summary.md'
            path.write_text(json.dumps(upstream_zlib_report()), encoding='utf-8')
            with patch.object(security, 'datetime') as clock, \
                    patch.dict(security.os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}), \
                    redirect_stdout(io.StringIO()) as output:
                clock.now.return_value.date.return_value = date(2026, 11, 9)
                self.assertEqual(security.main(path), 0)
            for text in (output.getvalue(), summary.read_text(encoding='utf-8')):
                self.assertIn('CVE-2026-85091', text)
                self.assertIn('2026-11-23', text)
                self.assertIn('not a vulnerability fix', text)

    def test_rejects_missing_or_malformed_scan_results(self):
        for data in ({}, {'SchemaVersion': 1, 'Results': []},
                     {'SchemaVersion': 2, 'Results': []},
                     {'SchemaVersion': 2, 'Results': [{}]}, report('invalid'),
                     report([{'FixedVersion': '2.0'}])):
            with self.subTest(data=data), self.assertRaises(ValueError):
                security.evaluate(data)

    def test_command_exit_status_blocks_findings_and_invalid_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'report.json'
            for content, expected in (
                (json.dumps(report([])), 0),
                (json.dumps(report([{'Severity': 'HIGH', 'FixedVersion': '2.0'}])), 1),
                ('not JSON', 1),
                ('{}', 1),
            ):
                path.write_text(content, encoding='utf-8')
                result = subprocess.run([sys.executable, str(SCRIPT), str(path)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
