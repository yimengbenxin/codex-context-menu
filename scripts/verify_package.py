import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
version = sys.argv[1] if len(sys.argv) > 1 else json.loads((root / "macos/Resources/adaptive/compatibility.json").read_text())["release"]
archive = root / f"dist/CodexContextMenu-{version}-macOS-arm64.zip"
with zipfile.ZipFile(archive) as bundle:
    names = bundle.namelist()
    assert not any(re.search(r"auth\.json|\.sqlite|runtime-events|install-backups|\.log$|\.pyc$", name) for name in names)
with tempfile.TemporaryDirectory() as temporary:
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
    folder = Path(temporary) / f"CodexContextMenu-{version}-macOS-arm64"
    app = folder / "CodexContextMenu.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run([sys.executable, "-B", str(root / "macos/script/install_local.py"), str(app), "--check"], check=True)
    assert (folder / "Install.command").stat().st_mode & 0o111
    assert (folder / "install_local.py").is_file()
    assert (app / "Contents/Resources/install_local.py").is_file()
    assert json.loads((app / "Contents/Resources/adaptive/defaults.json").read_text())["lower_percent"] == 35
    assert (app / "Contents/Resources/adaptive_preview.py").is_file()
    import plistlib
    assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == version
    resources = app / "Contents/Resources"
    for name in ("compaction_accounting.py", "compaction_observations.py", "adaptive/compaction-observer.mjs", "adaptive_preview.py"):
        assert (resources / name).read_bytes() == (root / "macos/Resources" / name).read_bytes()
    assert (folder / "Applications").is_symlink()
    executable = app / "Contents/MacOS/CodexTokenOverlayMac"
    strings = subprocess.check_output(["/usr/bin/strings", str(executable)], text=True)
    assert not re.search(r"/Users/[^/]+/|/home/[^/]+/|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}", strings)
    fallback_versions = []
    for legacy in (False, True):
        home = Path(temporary) / ("legacy-home" if legacy else "fresh-home")
        home.mkdir()
        if legacy:
            support = home / "Library/Application Support/CodexContextTool"
            support.mkdir(parents=True)
            (support / "official-adaptive-runtime.json").write_text('{"accepted":true,"release":"0.6.4"}')
        result = subprocess.run([str(app / "Contents/Resources/adaptive/backend"), "--version"],
            env={**os.environ, "HOME": str(home), "CODEX_HOME": str(home / ".codex"), "CODEX_CONTEXT_PYTHON": sys.executable},
            capture_output=True, text=True, check=True, timeout=45)
        assert result.stdout.startswith("codex-cli "), result.stdout
        fallback_versions.append(result.stdout.strip())
    assert fallback_versions[0] == fallback_versions[1]
    output = root / "artifacts" / f"packaged-canary-{version}.json"
    subprocess.run([sys.executable, "-B", str(root / "macos/Tests/test_adaptive_boundary.py")],
        env={**os.environ, "CODEX_CONTEXT_TEST_RESOURCES": str(resources), "CODEX_CONTEXT_TEST_OUTPUT": str(output)},
        stdout=subprocess.DEVNULL, check=True, timeout=180)
    canary = json.loads(output.read_text())
    assert canary["passed"] and canary["protected_config_and_official_binary_unchanged"]
    assert len(canary["compaction_observations"]["cases"]) == 2
    assert all(sample.get("accounting") for case in canary["compaction_observations"]["cases"] for sample in case["statistics"]["recent"])
print(json.dumps({"zip_signature_verified": True, "installer_present": True, "private_runtime_files_absent": True,
    "personal_build_paths_absent": True, "unintegrated_and_legacy_native_fallback": True, "packaged_native_canary": True}))
