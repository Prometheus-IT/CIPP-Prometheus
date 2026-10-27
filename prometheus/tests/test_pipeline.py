import importlib.util
import json
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

OVERLAY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pipeline", OVERLAY / "pipeline.py")
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        files = {
            "frontend/src/data/standards.json": json.dumps([{"name": "standards.Existing", "keep": {"x": [1, 2]}}]),
            "backend/Config/standards.json": json.dumps([{"name": "standards.Existing", "keep": {"x": [1, 2]}}]),
            "backend/Modules/CIPPCore/Public/GraphHelper/New-TeamsRequestV2.ps1":
                "$TenantFilter $Type $Action $Identity $Parameters",
            "backend/Modules/CIPPCore/Public/Set-CIPPStandardsCompareField.ps1": "$TenantFilter",
            "build/Dockerfile.release": "FROM scratch",
            "frontend/src/layouts/config.jsx": "export const nativeMenuItems = []\n",
        }
        for name, text in files.items():
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def test_preserves_existing_catalog_and_copies_backend(self):
        original = json.loads((self.source / "frontend/src/data/standards.json").read_text())
        self.assertEqual(pipeline.prepare(self.source), 1)
        combined = json.loads((self.source / "frontend/src/data/standards.json").read_text())
        self.assertEqual(combined[:-1], original)
        function = self.source / f"backend/Modules/CIPPStandards/Public/Standards/{pipeline.SOURCE_FILE}"
        self.assertEqual(function.read_bytes(), (OVERLAY / pipeline.SOURCE_FILE).read_bytes())

    def test_adds_standard_to_backend_catalog(self):
        backend = self.source / "backend/Config/standards.json"
        original = json.loads(backend.read_text())
        pipeline.prepare(self.source)
        combined = json.loads(backend.read_text())
        self.assertEqual(combined[:-1], original)
        self.assertEqual(combined[-1]["name"], f"standards.{pipeline.STANDARD}")

    def test_repeat_application_stops_without_overwriting(self):
        pipeline.prepare(self.source)
        catalogs = [self.source / path for path in pipeline.CATALOGS]
        before = [catalog.read_bytes() for catalog in catalogs]
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            pipeline.prepare(self.source)
        self.assertEqual([catalog.read_bytes() for catalog in catalogs], before)

    def test_backend_duplicate_stops_before_source_mutation(self):
        backend = self.source / "backend/Config/standards.json"
        backend.write_text(json.dumps([{"name": f"standards.{pipeline.STANDARD}"}]))
        frontend = self.source / "frontend/src/data/standards.json"
        before = frontend.read_bytes()
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            pipeline.prepare(self.source)
        self.assertEqual(frontend.read_bytes(), before)
        self.assertFalse((self.source / f"backend/Modules/CIPPStandards/Public/Standards/{pipeline.SOURCE_FILE}").exists())

    def test_changed_helper_stops_before_source_mutation(self):
        helper = self.source / "backend/Modules/CIPPCore/Public/GraphHelper/New-TeamsRequestV2.ps1"
        helper.write_text("$TenantFilter")
        before = (self.source / "frontend/src/data/standards.json").read_bytes()
        with self.assertRaisesRegex(ValueError, "contract changed"):
            pipeline.prepare(self.source)
        self.assertEqual((self.source / "frontend/src/data/standards.json").read_bytes(), before)

    def test_rejects_prerelease(self):
        with patch.object(pipeline, "api", return_value={"tag_name": "v12.0.0-preview", "draft": False, "prerelease": True}):
            with self.assertRaises(ValueError):
                pipeline.resolve()

    def test_resolves_exact_stable_commit_with_custom_version(self):
        with patch.object(pipeline, "api", side_effect=[
            {"tag_name": "v11.0.2", "draft": False, "prerelease": False}, {"sha": "a" * 40}
        ]):
            result = pipeline.resolve()
        self.assertEqual(result["upstream_sha"], "a" * 40)
        self.assertRegex(result["version"], r"^11\.0\.2\+prometheus\.aaaaaaaa\.[a-f0-9]{12}$")
        self.assertEqual(result["image_tag"], result["version"].replace("+", "-", 1))
        self.assertRegex(result["image_tag"], r"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$")
        self.assertEqual(result["build"], "true")

    def test_smoke_rejects_container_missing_compiled_standard(self):
        directory = self.source / "API/Modules/CIPPStandards"
        directory.mkdir(parents=True)
        (directory / "CIPPStandards.psd1").write_text("@{ FunctionsToExport = '*' }")
        (directory / "CIPPStandards.psm1").write_text("function Existing {}")
        with self.assertRaisesRegex(ValueError, "not compiled"):
            pipeline.smoke(self.source, "test")

    def write_packaged_app(self, backend_catalog):
        app = self.source / "app"
        files = {
            "API/Modules/CIPPStandards/CIPPStandards.psd1": "@{ FunctionsToExport = '*' }",
            "API/Modules/CIPPStandards/CIPPStandards.psm1":
                f"function {pipeline.FUNCTION} {{ 'FileSharingInChatsWithExternalUsers' }}",
            "API/Config/standards.json": json.dumps(backend_catalog),
            "API/Modules/CIPPHTTP/CIPPHTTP.psm1": "function Invoke-ListDefenderDashboard {}",
            "API/Modules/CIPPHTTP/CIPPHTTP.psd1": "@{ FunctionsToExport = '*' }",
            "Frontend/version.json": json.dumps({"version": "test", "tag": "latest"}),
            "Frontend/_next/static/app.js": f"standards.{pipeline.STANDARD}",
            "Frontend/index.html": "",
        }
        for name, text in files.items():
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        for name in ("API/Modules/CIPPCore", "API/Modules/CIPPHTTP"):
            (app / name).mkdir(parents=True, exist_ok=True)
        http = app / "API/Modules/CIPPHTTP/CIPPHTTP.psm1"
        for path in pipeline.avd_overlay_files():
            if path.suffix == '.ps1' and 'Modules' in path.parts:
                with http.open('a') as output:
                    output.write(f'\nfunction {path.stem} {{}}')
        portal = app / 'Frontend/_next/static/app.js'
        with portal.open('a') as output:
            output.write(' ListPiAvdHostPools ListPiAvdSessionHosts ListPiAvdUserSessions'
                         ' ExecPiAvdSessionHost ExecPiAvdUserSession')
        for page in pipeline.AVD_PAGES:
            route = app / f'Frontend/custom/avd/{page}/index.html'
            route.parent.mkdir(parents=True, exist_ok=True)
            route.write_text('AVD page')
        return app

    def test_prepare_copies_avd_sources_tests_and_appends_menu_hook(self):
        menu = self.source / pipeline.AVD_MENU
        original = menu.read_text()
        pipeline.prepare(self.source)
        self.assertTrue(menu.read_text().startswith(original))
        self.assertEqual(menu.read_text().count('applyCustomMenuItems(nativeMenuItems)'), 1)
        for path in pipeline.avd_overlay_files():
            target = self.source / path.relative_to(pipeline.ROOT.parent)
            self.assertEqual(target.read_bytes(), path.read_bytes())

    def test_avd_collision_stops_before_any_overlay_write(self):
        existing = self.source / pipeline.avd_overlay_files()[0].relative_to(pipeline.ROOT.parent)
        existing.parent.mkdir(parents=True, exist_ok=True)
        existing.write_text('upstream implementation')
        catalog = self.source / pipeline.CATALOGS[0]
        before = catalog.read_bytes()
        with self.assertRaisesRegex(ValueError, 'already contains an AVD'):
            pipeline.prepare(self.source)
        self.assertEqual(catalog.read_bytes(), before)
        self.assertFalse((self.source / f'backend/Modules/CIPPStandards/Public/Standards/{pipeline.SOURCE_FILE}').exists())

    def test_changed_menu_contract_stops_before_any_overlay_write(self):
        (self.source / pipeline.AVD_MENU).write_text('export const renamedMenu = []')
        with self.assertRaisesRegex(ValueError, 'navigation contract changed'):
            pipeline.prepare(self.source)
        self.assertFalse((self.source / f'backend/Modules/CIPPStandards/Public/Standards/{pipeline.SOURCE_FILE}').exists())

    def test_avd_source_changes_invalidate_image_version(self):
        repo = self.source / 'hash-repo'
        overlay = repo / 'prometheus'
        overlay.mkdir(parents=True)
        workflow = repo / '.github/workflows/prometheus-container.yml'
        workflow.parent.mkdir(parents=True)
        workflow.write_text('workflow')
        addition = repo / 'backend/avd.ps1'
        addition.parent.mkdir(parents=True)
        addition.write_text('first')
        with patch.object(pipeline, 'ROOT', overlay), \
                patch.object(pipeline, 'avd_overlay_files', return_value=[addition]):
            first = pipeline.overlay_hash()
            addition.write_text('second')
            self.assertNotEqual(pipeline.overlay_hash(), first)

    def test_smoke_rejects_missing_avd_function(self):
        app = self.write_packaged_app([{'name': f'standards.{pipeline.STANDARD}'}])
        module = app / 'API/Modules/CIPPHTTP/CIPPHTTP.psm1'
        module.write_text(module.read_text().replace('function Get-PiArmToken {}', ''))
        with self.assertRaisesRegex(ValueError, 'AVD function is missing'):
            pipeline.smoke(app, 'test')

    def test_smoke_rejects_missing_avd_page(self):
        app = self.write_packaged_app([{'name': f'standards.{pipeline.STANDARD}'}])
        (app / 'Frontend/custom/avd/sessions/index.html').unlink()
        with self.assertRaisesRegex(ValueError, 'AVD frontend page is missing'):
            pipeline.smoke(app, 'test')

    def test_smoke_rejects_missing_avd_portal_action(self):
        app = self.write_packaged_app([{'name': f'standards.{pipeline.STANDARD}'}])
        portal = app / 'Frontend/_next/static/app.js'
        portal.write_text(portal.read_text().replace('ExecPiAvdUserSession', ''))
        with self.assertRaisesRegex(ValueError, 'AVD frontend endpoint is missing'):
            pipeline.smoke(app, 'test')

    def test_smoke_accepts_complete_container(self):
        app = self.write_packaged_app([{"name": f"standards.{pipeline.STANDARD}"}])
        pipeline.smoke(app, "test")

    def test_smoke_rejects_missing_dashboard_endpoint(self):
        app = self.write_packaged_app([{"name": f"standards.{pipeline.STANDARD}"}])
        (app / 'API/Modules/CIPPHTTP/CIPPHTTP.psm1').write_text('function Other {}')
        with self.assertRaisesRegex(ValueError, 'dashboard endpoint'):
            pipeline.smoke(app, 'test')

    def test_smoke_rejects_container_missing_backend_catalog_entry(self):
        app = self.write_packaged_app([{"name": "standards.Existing"}])
        with self.assertRaisesRegex(ValueError, "backend standards catalog"):
            pipeline.smoke(app, "test")

    def resolve_recorded_build(self, recorded_sha="a" * 40, force=False, recorded_version=None):
        (self.source / "build-state.json").write_text(json.dumps({
            "version": recorded_version or "11.0.2+prometheus.aaaaaaaa.123456789abc.build.12345",
            "upstream_sha": recorded_sha,
        }))
        with patch.object(pipeline, "ROOT", self.source), \
                patch.object(pipeline, "overlay_hash", return_value="123456789abc"), \
                patch.object(pipeline, "api", side_effect=[
                    {"tag_name": "v11.0.2", "draft": False, "prerelease": False},
                    {"sha": "a" * 40},
                ]), patch.dict(os.environ, {"GITHUB_RUN_ID": "67890"}):
            return pipeline.resolve(force)

    def test_daily_check_preserves_successful_forced_build(self):
        self.assertEqual(self.resolve_recorded_build()["build"], "false")

    def test_changed_upstream_still_builds_after_forced_build(self):
        self.assertEqual(self.resolve_recorded_build(recorded_sha="b" * 40)["build"], "true")

    def test_requested_forced_rebuild_gets_distinct_version(self):
        result = self.resolve_recorded_build(force=True)
        self.assertEqual(result["build"], "true")
        self.assertEqual(result["version"], "11.0.2+prometheus.aaaaaaaa.123456789abc.build.67890")
        self.assertEqual(result["image_tag"], "11.0.2-prometheus.aaaaaaaa.123456789abc.build.67890")

    def test_existing_prerelease_version_is_rebuilt_with_correct_metadata(self):
        result = self.resolve_recorded_build(recorded_version="11.0.2-prometheus.aaaaaaaa.123456789abc")
        self.assertEqual(result["build"], "true")
        self.assertEqual(result["version"], "11.0.2+prometheus.aaaaaaaa.123456789abc")


if __name__ == "__main__":
    unittest.main()
