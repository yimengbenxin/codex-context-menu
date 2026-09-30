import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/CodexContextTool"
APPLICATION = HOME / "Applications/CodexContextMenu.app"
DESKTOP = HOME / "Desktop/Codex 上下文.app"
BACKEND = SUPPORT / "backend"
MANIFEST = SUPPORT / "official-adaptive-runtime.json"
INTEGRATION = SUPPORT / "official-adaptive-integration.json"
PLIST = HOME / "Library/LaunchAgents/local.wen.CodexContextMenu.plist"
LABEL = f"gui/{os.getuid()}/local.wen.CodexContextMenu"


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def command(*arguments, check=True):
    return subprocess.run(arguments, capture_output=True, text=True, check=check)


def verify_bundle(bundle):
    with tempfile.TemporaryDirectory(prefix="context-signature-") as temporary:
        copy = Path(temporary) / bundle.name
        copy_bundle(bundle, copy)
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(copy))


def clear_finder_metadata(bundle):
    for attribute in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
        command("/usr/bin/xattr", "-rd", attribute, str(bundle), check=False)


def copy_bundle(source, destination):
    shutil.copytree(source, destination)
    quarantine = command("/usr/bin/xattr", "-p", "com.apple.quarantine", str(source), check=False)
    if quarantine.returncode == 0 and quarantine.stdout.strip():
        command("/usr/bin/xattr", "-w", "com.apple.quarantine", quarantine.stdout.strip(), str(destination))
    clear_finder_metadata(destination)


def menu_stop():
    command("/bin/launchctl", "bootout", LABEL, check=False)
    processes = command("/bin/ps", "-axo", "pid=,command=").stdout.splitlines()
    executable = str(APPLICATION / "Contents/MacOS/CodexTokenOverlayMac")
    for line in processes:
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == executable or parts[1].startswith(executable + " ")):
            os.kill(int(parts[0]), signal.SIGTERM)


def menu_start():
    result = command("/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST), check=False)
    if result.returncode:
        command("/bin/launchctl", "kickstart", LABEL)


candidate = Path(sys.argv[1]).resolve(strict=True)
if sys.version_info < (3, 11):
    raise RuntimeError("Python 3.11 or later is required")
if candidate.name != "CodexContextMenu.app":
    raise ValueError("Unexpected application bundle")
verify_bundle(candidate)
resources = candidate / "Contents/Resources"
compatibility = json.loads((resources / "adaptive/compatibility.json").read_text())
sys.path[:0] = [str(resources), str(Path(__file__).parent.parent / "Resources")]
from runtime_probe import locate
runtime = locate()
assert not (resources / "adaptive/desktop-check.mjs").exists()
for file in (resources / "adaptive").glob("*.mjs"):
    assert "get_usage_limits" not in file.read_text() and "CODEX_CONTEXT_DESKTOP_CHECK" not in file.read_text()
if "--check" in sys.argv[2:]:
    print(json.dumps({"compatible": True, "release": compatibility["release"], "runtime": runtime, "writes": False}))
    raise SystemExit(0)
integrate_only = "--integrate-only" in sys.argv[2:]
preserve_window = "--preserve-window" in sys.argv[2:]
if integrate_only:
    APPLICATION = candidate

baseline_config = Path(os.environ.get("CODEX_HOME", str(HOME / ".codex"))) / "config.toml"
baseline = baseline_config.read_bytes() if baseline_config.exists() else None
backup = SUPPORT / "install-backups" / str(time.time_ns())
backup.mkdir(parents=True, mode=0o700)
for file in [BACKEND, MANIFEST, INTEGRATION, PLIST]:
    if file.exists() or file.is_symlink():
        shutil.copy2(file, backup / file.name, follow_symlinks=False)
if APPLICATION.exists() and not integrate_only:
    shutil.copytree(APPLICATION, backup / APPLICATION.name)
if DESKTOP.exists():
    shutil.copytree(DESKTOP, backup / DESKTOP.name)
if not integrate_only:
    staged = APPLICATION.with_name("CodexContextMenu.installing.app")
    APPLICATION.parent.mkdir(parents=True, exist_ok=True)
    if staged.exists():
        raise RuntimeError("Unfinished installation staging directory exists")
    copy_bundle(candidate, staged)
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged))
    if not preserve_window:
        menu_stop()
try:
    if not integrate_only:
        if APPLICATION.exists():
            shutil.rmtree(APPLICATION)
        staged.rename(APPLICATION)
    adaptive = APPLICATION / "Contents/Resources/adaptive"
    if BACKEND.exists() or BACKEND.is_symlink():
        BACKEND.unlink()
    BACKEND.symlink_to(adaptive / "backend")
    if not integrate_only:
        (adaptive / "backend").chmod(0o755)
    all_files = {}
    for file in (APPLICATION / "Contents/Resources").rglob("*"):
        if file.is_file() and ("adaptive" in file.parts or "vendor" in file.parts or "usage" in file.parts or file.name in ("context_config.py", "thread_settings.py", "runtime_probe.py", "adaptive_settings.py")):
            all_files[os.path.relpath(file, adaptive)] = digest(file)
    manifest = {"accepted": True, "scope": "synthetic-runtime-lifecycle-and-genuine-desktop-tools",
        "real_long_history_accepted": False, **runtime, "python": sys.executable,
        "files": all_files, "release": compatibility["release"], "backup": str(backup)}
    temporary = MANIFEST.with_suffix(".tmp")
    temporary.write_text(json.dumps(manifest, indent=2))
    temporary.chmod(0o600)
    temporary.replace(MANIFEST)
    capability = json.loads(command(str(BACKEND), "--context-capability").stdout)
    assert capability["adaptive"], capability
    command(str(BACKEND), "--enable-integration")
    assert (baseline_config.read_bytes() if baseline_config.exists() else None) == baseline, "Global configuration changed during installation"
    if DESKTOP.exists():
        icon_directory = DESKTOP / "Contents/Resources"
        icon_directory.mkdir(exist_ok=True)
        shutil.copy2(APPLICATION / "Contents/Resources/ContextIcon.icns", icon_directory / "ContextIcon.icns")
        desktop_plist = DESKTOP / "Contents/Info.plist"
        fields = plistlib.loads(desktop_plist.read_bytes())
        fields["CFBundleIconFile"] = "ContextIcon"
        fields["CFBundleVersion"] = plistlib.loads((APPLICATION / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        fields["CFBundleShortVersionString"] = fields["CFBundleVersion"]
        desktop_plist.write_bytes(plistlib.dumps(fields))
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    logs = HOME / "Library/Logs"
    logs.mkdir(parents=True, exist_ok=True)
    PLIST.write_bytes(plistlib.dumps({"Label": "local.wen.CodexContextMenu", "RunAtLoad": True,
        "ProgramArguments": [str(APPLICATION / "Contents/MacOS/CodexTokenOverlayMac"), "--background"],
        "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": str(logs / "CodexContextMenu.log"), "StandardErrorPath": str(logs / "CodexContextMenu.log")}))
    if not integrate_only and not preserve_window:
        menu_start()
    version = plistlib.loads((APPLICATION / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
    report = {"installed": True, "version": version, "backup": str(backup),
        "main_restart_required_once": True, "global_config_unchanged": True,
        "quota_reader_installed": True, "automatic_quota_default": False, "quota_source": "CodexBar OAuth; official OpenAI"}
    (SUPPORT / "installation.json").write_text(json.dumps(report, indent=2) + "\n")
    if not integrate_only and not preserve_window:
        command("/usr/bin/open", "-a", str(APPLICATION), "--args", "--show-settings")
    print(json.dumps(report))
except Exception:
    if BACKEND.exists():
        command(str(BACKEND), "--restore-official", check=False)
    if APPLICATION.exists() and not integrate_only:
        shutil.rmtree(APPLICATION)
    if (backup / APPLICATION.name).exists() and not integrate_only:
        shutil.copytree(backup / APPLICATION.name, APPLICATION)
    if (backup / DESKTOP.name).exists():
        if DESKTOP.exists():
            shutil.rmtree(DESKTOP)
        shutil.copytree(backup / DESKTOP.name, DESKTOP)
    for file in [BACKEND, MANIFEST, INTEGRATION, PLIST]:
        if file.exists() or file.is_symlink():
            file.unlink()
        if (backup / file.name).exists() or (backup / file.name).is_symlink():
            shutil.copy2(backup / file.name, file, follow_symlinks=False)
    if PLIST.exists() and not integrate_only and not preserve_window:
        menu_start()
    raise
