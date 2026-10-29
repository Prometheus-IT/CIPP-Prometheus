import importlib.util
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


class ImageSecurityTests(unittest.TestCase):
    def test_blocks_high_and_critical_with_fixes_across_results(self):
        data = report([{'Severity': 'HIGH', 'FixedVersion': '2.0'}])
        data['Results'].append({'Target': 'library', 'Vulnerabilities': [
            {'Severity': 'CRITICAL', 'FixedVersion': '3.0'}]})
        findings, blocked = security.evaluate(data)
        self.assertEqual(len(findings), 2)
        self.assertEqual(len(blocked), 2)

    def test_retains_unfixed_and_lower_severity_without_blocking(self):
        findings, blocked = security.evaluate(report([
            {'Severity': 'CRITICAL'}, {'Severity': 'HIGH', 'FixedVersion': ''},
            {'Severity': 'MEDIUM', 'FixedVersion': '2.0'}, {'Severity': 'UNKNOWN'}]))
        self.assertEqual(len(findings), 4)
        self.assertEqual(blocked, [])

    def test_accepts_clean_scanned_result(self):
        self.assertEqual(security.evaluate(report(None)), ([], []))

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
