import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources"))

SCRIPT = Path(__file__).resolve().parents[1] / "script/install_local.py"
OFFICIAL = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
NODE = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"


class InstallerTests(unittest.TestCase):
    def exercise(self, fail=False, integrate_only=False, preserve_window=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "fresh-home"
            home.mkdir()
            candidate = root / "release/CodexContextMenu.app"
            resources = candidate / "Contents/Resources"
            (resources / "adaptive").mkdir(parents=True)
            (resources / "adaptive/backend").write_text("fixture backend")
            (candidate / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.6.4"}))
            fixtures = {OFFICIAL: b"fixture official", NODE: b"fixture signed node"}
            (resources / "adaptive/compatibility.json").write_text(json.dumps({"release": "0.6.4",
                "officialSha256": hashlib.sha256(fixtures[OFFICIAL]).hexdigest(),
                "nodeSha256": hashlib.sha256(fixtures[NODE]).hexdigest()}))
            support = home / "Library/Application Support/CodexContextTool"
            application = home / "Applications/CodexContextMenu.app"
            if integrate_only:
                application = candidate.resolve()
            agent = home / "Library/LaunchAgents/local.wen.CodexContextMenu.plist"
            if fail:
                shutil.copytree(candidate, application)
                (application / "previous-marker").write_text("old installation")
                support.mkdir(parents=True)
                (support / "official-adaptive-runtime.json").write_text('{"baseline":true}')
                agent.parent.mkdir(parents=True)
                agent.write_bytes(b"previous launch agent")
            original_read = Path.read_bytes
            original_is_file = Path.is_file
            calls = []

            def read(file):
                return fixtures[str(file)] if str(file) in fixtures else original_read(file)

            def is_file(file):
                return True if str(file) in fixtures else original_is_file(file)

            def command(arguments, **options):
                calls.append(arguments)
                if fail and "--enable-integration" in arguments:
                    raise subprocess.CalledProcessError(1, arguments, stderr="fixture activation failure")
                output = '{"adaptive":true}' if "--context-capability" in arguments else ""
                return subprocess.CompletedProcess(arguments, 0, stdout=output, stderr="")

            with patch.dict(os.environ, {"HOME": str(home), "CODEX_HOME": str(home / ".codex")}), \
                 patch.object(sys, "argv", [str(SCRIPT), str(candidate)] + (["--integrate-only"] if integrate_only else []) + (["--preserve-window"] if preserve_window else [])), \
                 patch("runtime_probe.locate", return_value={"binary": OFFICIAL, "node": NODE,
                     "contract": "round-boundary-v1", "version": "fixture 0.159.0", "officialSha256": hashlib.sha256(fixtures[OFFICIAL]).hexdigest(),
                     "nodeSha256": hashlib.sha256(fixtures[NODE]).hexdigest()}), \
                 patch.object(Path, "read_bytes", read), patch.object(Path, "is_file", is_file), \
                 patch.object(subprocess, "run", command), contextlib.redirect_stdout(io.StringIO()):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        runpy.run_path(str(SCRIPT), run_name="__main__")
                else:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            self.assertFalse((home / ".codex").exists())
            self.assertTrue(application.exists())
            self.assertTrue(agent.exists())
            if fail:
                self.assertEqual((application / "previous-marker").read_text(), "old installation")
                self.assertEqual((support / "official-adaptive-runtime.json").read_text(), '{"baseline":true}')
                self.assertEqual(agent.read_bytes(), b"previous launch agent")
                self.assertTrue(any("--restore-official" in call for call in calls))
            else:
                config = plistlib.loads(agent.read_bytes())
                self.assertTrue(config["RunAtLoad"])
                self.assertEqual(config["ProgramArguments"][0], str(application / "Contents/MacOS/CodexTokenOverlayMac"))
                self.assertEqual(config["ProgramArguments"][1], "--background")
                self.assertTrue((support / "backend").is_symlink())
                self.assertTrue((support / "installation.json").exists())
                manifest = json.loads((support / "official-adaptive-runtime.json").read_text())
                self.assertNotIn("nativeEvidence", manifest)
                self.assertNotIn("desktopEvidence", manifest)
                if preserve_window:
                    self.assertFalse(any("bootstrap" in call or "/usr/bin/open" in call for call in calls))

    def test_fresh_home_install_without_private_acceptance_files(self):
        self.exercise()

    def test_activation_failure_restores_previous_app_manifest_and_agent(self):
        self.exercise(fail=True)

    def test_dragged_app_can_complete_runtime_integration_without_copying_it_again(self):
        self.exercise(integrate_only=True)
        self.exercise(preserve_window=True)
