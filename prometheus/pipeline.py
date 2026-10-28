"""Build released CIPP source with a small, validated Prometheus overlay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parent
STANDARD = "PrometheusTeamsExternalChatFiles"
FUNCTION = f"Invoke-CIPPStandard{STANDARD}"
SOURCE_FILE = f"{FUNCTION}.ps1"
CATALOGS = ("frontend/src/data/standards.json", "backend/Config/standards.json")
AVD_ROOTS = (
    "backend/Modules/CIPPHTTP/Public/Custom/AVD",
    "backend/Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Custom/AVD",
    "backend/Tests/Custom/PiAvd.Tests.ps1",
    "frontend/src/custom/menu.jsx",
    "frontend/src/custom/avd",
    "frontend/src/pages/custom/avd",
    "frontend/tests/custom",
)
AVD_PAGES = ("host-pools", "session-hosts", "sessions")
AVD_MENU = "frontend/src/layouts/config.jsx"
AVD_HOOK = ('\n// Prometheus Azure Virtual Desktop navigation.\n'
            'import { applyCustomMenuItems } from "../custom/menu";\n'
            'applyCustomMenuItems(nativeMenuItems);\n')


def avd_overlay_files():
    files = []
    for name in AVD_ROOTS:
        path = ROOT.parent / name
        if not path.exists():
            raise ValueError(f"AVD overlay input missing: {name}")
        files.extend([path] if path.is_file() else
                     sorted(p for p in path.rglob("*") if p.is_file()))
    return files


def api(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Prometheus-CIPP-build"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    request = urllib.request.Request(f"https://api.github.com{path}", headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def overlay_hash():
    digest = hashlib.sha256()
    files = [p for p in ROOT.rglob("*") if p.is_file() and
             p.name != "build-state.json" and "__pycache__" not in p.parts]
    files.append(ROOT.parent / ".github/workflows/prometheus-container.yml")
    files.extend(avd_overlay_files())
    for path in sorted(files):
        digest.update(path.relative_to(ROOT.parent).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes().replace(b"\r\n", b"\n"))
        digest.update(b"\0")
    return digest.hexdigest()[:12]


def resolve(force=False):
    release = api("/repos/CyberDrain/CIPP/releases/latest")
    tag = release["tag_name"]
    if release["draft"] or release["prerelease"] or not re.fullmatch(r"v?\d+\.\d+\.\d+", tag):
        raise ValueError("Only an official stable semantic-version release can be built")
    commit = api(f"/repos/CyberDrain/CIPP/commits/{tag}")["sha"]
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Invalid upstream commit")
    # The overlay is build metadata on an official stable release, not a
    # prerelease. CIPP's SemVer comparison must consider it equal to that release.
    base_version = f"{tag.removeprefix('v')}+prometheus.{commit[:8]}.{overlay_hash()}"
    version = base_version
    if force and os.environ.get("GITHUB_RUN_ID"):
        version += f".build.{os.environ['GITHUB_RUN_ID']}"
    state_path = ROOT / "build-state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    # A forced rebuild is still the same released source and overlay. Do not
    # republish the old base tag or restart production again on the next check.
    recorded_base = re.sub(r"\.build\.\d+$", "", state.get("version", ""))
    # OCI image tags cannot contain '+'. Keep a separate Docker-compatible tag;
    # APP_VERSION and the OCI version label retain the complete SemVer metadata.
    return {"tag": tag, "upstream_sha": commit, "version": version,
            "image_tag": version.replace("+", "-", 1),
            "build": str(force or recorded_base != base_version or
                         state.get("upstream_sha") != commit).lower()}


def prepare(source):
    source = Path(source).resolve()
    additions = json.loads((ROOT / "standards.json").read_text(encoding="utf-8"))
    if len(additions) != 1:
        raise ValueError("Unexpected standards catalog format")
    item = additions[0]
    if item["name"] != f"standards.{STANDARD}" or not item["addedComponent"][0]["required"]:
        raise ValueError("Invalid custom standard metadata")
    if [o["value"] for o in item["addedComponent"][0]["options"]] != ["Enabled", "Disabled"]:
        raise ValueError("The standard must require an explicit Enabled/Disabled choice")
    # The portal reads the frontend catalog; the executive report, template repair and
    # tests read the backend copy. Validate both catalogs before touching any source file.
    catalogs = [merged_catalog(source / path, additions) for path in CATALOGS]
    destination = source / f"backend/Modules/CIPPStandards/Public/Standards/{SOURCE_FILE}"
    if destination.exists():
        raise ValueError("Upstream already contains the custom function; review before updating")
    helper = (source / "backend/Modules/CIPPCore/Public/GraphHelper/New-TeamsRequestV2.ps1").read_text()
    for parameter in ("TenantFilter", "Type", "Action", "Identity", "Parameters"):
        if f"${parameter}" not in helper:
            raise ValueError(f"Teams request contract changed: missing {parameter}")
    compare = next(source.glob("backend/Modules/**/Set-CIPPStandardsCompareField.ps1"))
    if "$TenantFilter" not in compare.read_text():
        raise ValueError("Standards comparison contract changed")
    if not (source / "build/Dockerfile.release").is_file():
        raise ValueError("Official release Dockerfile is missing")
    # Validate every addition and the small navigation patch before mutating source.
    avd_files = avd_overlay_files()
    for path in avd_files:
        target = source / path.relative_to(ROOT.parent)
        if target.exists():
            raise ValueError(f"Upstream already contains an AVD overlay file: {target}")
    menu_path = source / AVD_MENU
    menu = menu_path.read_text(encoding="utf-8")
    if not re.search(r"export\s+const\s+nativeMenuItems\s*=", menu) or "applyCustomMenuItems" in menu:
        raise ValueError("AVD navigation contract changed; review before updating")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / SOURCE_FILE, destination)
    dashboard = source / 'backend/Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Security/Defender/Invoke-ListDefenderDashboard.ps1'
    if dashboard.exists():
        raise ValueError('Upstream already contains the dashboard endpoint; review required')
    dashboard.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'Invoke-ListDefenderDashboard.ps1', dashboard)
    for path in avd_files:
        target = source / path.relative_to(ROOT.parent)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    menu_path.write_text(menu.rstrip() + "\n" + AVD_HOOK, encoding="utf-8")
    for path, (_, encoded) in zip(CATALOGS, catalogs):
        (source / path).write_text(encoded, encoding="utf-8")
    return len(catalogs[0][0])


def normalize_esp_components(catalog):
    """Keep ESP editor fields relative to the standard, as the form expects.

    The legacy ESP catalog already prefixes its field names with
    standards.AutopilotStatusPage. The editor adds that prefix itself, so
    leaving both puts the settings in an unused nested standards object.
    """
    normalized = json.loads(json.dumps(catalog))
    prefix = "standards.AutopilotStatusPage."
    for item in normalized:
        if item.get("name") != "standards.AutopilotStatusPage":
            continue
        for component in item.get("addedComponent", []):
            name = component.get("name")
            if isinstance(name, str) and name.startswith(prefix):
                component["name"] = name[len(prefix):]
    return normalized


def merged_catalog(path, additions):
    catalog = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(catalog, list):
        raise ValueError(f"Unexpected standards catalog format: {path}")
    names = [i["name"] for i in catalog]
    if len(names) != len(set(names)) or additions[0]["name"] in names:
        raise ValueError("Duplicate standard identifier; stop rather than overwrite")
    # Normalize only the legacy ESP editor field paths; policy settings and all
    # other upstream standards are preserved. Apply to both maintained catalogs.
    normalized_catalog = normalize_esp_components(catalog)
    encoded = json.dumps(normalized_catalog + additions, indent=2, ensure_ascii=False) + "\n"
    if json.loads(encoded)[:-1] != normalized_catalog:
        raise ValueError("Unexpected catalog changes after ESP field normalization")
    return catalog, encoded


def smoke(app, version):
    app = Path(app)
    module_dir = app / "API/Modules/CIPPStandards"
    manifest = next(module_dir.rglob("CIPPStandards.psd1"))
    module = next(manifest.parent.glob("CIPPStandards.psm1"))
    text = module.read_text(encoding="utf-8-sig")
    if not re.search(rf"function\s+{FUNCTION}\s*\{{", text, re.I):
        raise ValueError("Custom standard was not compiled into the runtime module")
    if "FileSharingInChatsWithExternalUsers" not in text:
        raise ValueError("Compiled policy setting missing")
    manifest_text = manifest.read_text(encoding="utf-8-sig")
    if FUNCTION not in manifest_text and not re.search(r"FunctionsToExport\s*=\s*['\"]\*", manifest_text):
        raise ValueError("Runtime module does not export the custom standard")
    metadata = json.loads((app / "Frontend/version.json").read_text())
    if metadata["version"] != version or metadata["tag"] != "latest":
        raise ValueError("Container version does not match the updater channel")
    javascript = list((app / "Frontend/_next").rglob("*.js"))
    if not any(f"standards.{STANDARD}" in p.read_text(encoding="utf-8") for p in javascript):
        raise ValueError("Custom standard is missing from the built portal catalog")
    backend_catalog = json.loads((app / "API/Config/standards.json").read_text(encoding="utf-8"))
    if not any(i.get("name") == f"standards.{STANDARD}" for i in backend_catalog):
        raise ValueError("Custom standard is missing from the backend standards catalog")
    for path in ("API/Modules/CIPPCore", "API/Modules/CIPPHTTP", "Frontend/index.html"):
        if not (app / path).exists():
            raise ValueError(f"Required runtime artifact missing: {path}")
    http_module = next((app / 'API/Modules/CIPPHTTP').rglob('CIPPHTTP.psm1')).read_text(encoding='utf-8-sig')
    if not re.search(r'function\s+Invoke-ListDefenderDashboard\s*\{', http_module, re.I):
        raise ValueError('Read-only Defender dashboard endpoint is missing from the runtime module')
    http_manifest = next((app / 'API/Modules/CIPPHTTP').rglob('CIPPHTTP.psd1')).read_text(encoding='utf-8-sig')
    wildcard_exports = re.search(r"FunctionsToExport\s*=\s*['\"]\*", http_manifest)
    for path in avd_overlay_files():
        if path.suffix != '.ps1' or 'Modules' not in path.parts:
            continue
        name = path.stem
        if not re.search(rf'function\s+{re.escape(name)}\s*\{{', http_module, re.I):
            raise ValueError(f'AVD function is missing from the runtime module: {name}')
        if not wildcard_exports and name not in http_manifest:
            raise ValueError(f'Runtime module does not export AVD function: {name}')
    for page in AVD_PAGES:
        route = app / 'Frontend/custom/avd' / page
        if not route.with_suffix('.html').is_file() and not (route / 'index.html').is_file():
            raise ValueError(f'AVD frontend page is missing from the built portal: {page}')
    portal_js = '\n'.join(p.read_text(encoding='utf-8') for p in javascript)
    for endpoint in ('ListPiAvdHostPools', 'ListPiAvdSessionHosts', 'ListPiAvdUserSessions',
                     'ExecPiAvdSessionHost', 'ExecPiAvdUserSession'):
        if endpoint not in portal_js:
            raise ValueError(f'AVD frontend endpoint is missing from the built portal: {endpoint}')


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("resolve")
    plan.add_argument("--force", action="store_true")
    commands.add_parser("prepare").add_argument("source")
    check = commands.add_parser("smoke")
    check.add_argument("app")
    check.add_argument("version")
    args = parser.parse_args()
    if args.command == "resolve":
        values = resolve(args.force)
        print(json.dumps(values))
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                for key, value in values.items():
                    output.write(f"{key}={value}\n")
    elif args.command == "prepare":
        print(f"Preserved {prepare(args.source)} upstream standards; added {STANDARD}")
    else:
        smoke(args.app, args.version)
        print("Built backend export, portal and backend catalogs, runtime files and updater version verified")

