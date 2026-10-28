"""Regression checks for the ESP field paths delivered by the publisher."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PIPELINE = Path(os.environ.get("CIPP_PIPELINE_PATH", ROOT / "prometheus/pipeline.py"))
CATALOG = Path(os.environ.get("CIPP_CATALOG_PATH", ROOT / "frontend/src/data/standards.json"))
spec = importlib.util.spec_from_file_location("esp_pipeline", PIPELINE)
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)

class EspEditorCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))

    def normalize(self, catalog):
        # The fallback deliberately reproduces the released publisher behavior.
        return getattr(pipeline, "normalize_esp_components", lambda value: value)(catalog)

    def test_real_esp_fields_bind_exactly_once(self):
        esp = next(item for item in self.normalize(self.catalog)
                   if item["name"] == "standards.AutopilotStatusPage")
        expected = {"TimeOutInMinutes", "ErrorMessage", "ShowProgress", "EnableLog",
                    "OBEEOnly", "InstallWindowsUpdates", "BlockDevice",
                    "AllowReset", "AllowFail"}
        self.assertEqual({field["name"] for field in esp["addedComponent"]}, expected)
        for field in esp["addedComponent"]:
            self.assertEqual(
                f'{esp["name"]}.{field["name"]}',
                f'standards.AutopilotStatusPage.{field["name"].split(".")[-1]}'
            )

    def test_flat_settings_reach_the_backend_shape(self):
        esp = next(item for item in self.normalize(self.catalog)
                   if item["name"] == "standards.AutopilotStatusPage")
        form = {}
        for component in esp["addedComponent"]:
            target = form
            parts = f'{esp["name"]}.{component["name"]}'.split(".")
            for part in parts[:-1]:
                target = target.setdefault(part, {})
            target[parts[-1]] = False if component["type"] == "switch" else "value"
        settings = form["standards"]["AutopilotStatusPage"]
        self.assertIn("TimeOutInMinutes", settings)
        self.assertIn("InstallWindowsUpdates", settings)
        self.assertNotIn("standards", settings)
        self.assertIs(settings["AllowFail"], False)

    def test_all_other_standards_are_unchanged(self):
        result = self.normalize(self.catalog)
        self.assertEqual(
            [item for item in result if item["name"] != "standards.AutopilotStatusPage"],
            [item for item in self.catalog if item["name"] != "standards.AutopilotStatusPage"]
        )

    def test_esp_metadata_is_preserved(self):
        before = next(item for item in self.catalog
                      if item["name"] == "standards.AutopilotStatusPage")
        after = next(item for item in self.normalize(self.catalog)
                     if item["name"] == "standards.AutopilotStatusPage")
        self.assertEqual(
            {key: value for key, value in before.items() if key != "addedComponent"},
            {key: value for key, value in after.items() if key != "addedComponent"}
        )
        for old, new in zip(before["addedComponent"], after["addedComponent"]):
            self.assertEqual({k:v for k,v in old.items() if k != "name"},
                             {k:v for k,v in new.items() if k != "name"})

    def test_normalization_is_idempotent_and_does_not_mutate_inputs(self):
        original = json.loads(json.dumps(self.catalog))
        once = self.normalize(self.catalog)
        self.assertEqual(self.normalize(once), once)
        self.assertEqual(self.catalog, original)

    def test_publisher_merges_the_fixed_catalog_and_custom_standard(self):
        additions = [{"name": "standards.PrometheusTeamsExternalChatFiles"}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "standards.json"
            path.write_text(json.dumps(self.catalog), encoding="utf-8")
            returned, encoded = pipeline.merged_catalog(path, additions)
        self.assertEqual(returned, self.catalog)
        merged = json.loads(encoded)
        self.assertEqual(merged[:-1], self.normalize(self.catalog))
        self.assertEqual(merged[-1], additions[0])
        esp = next(item for item in merged
                   if item["name"] == "standards.AutopilotStatusPage")
        self.assertEqual(esp["addedComponent"][0]["name"], "TimeOutInMinutes")

if __name__ == "__main__":
    unittest.main(verbosity=2)

