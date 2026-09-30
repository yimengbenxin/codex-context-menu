import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import importlib.util

SCRIPT = Path(__file__).resolve().parents[1] / "Resources/context_config.py"
PYTHON = Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
FIRST = "11111111-1111-4111-8111-111111111111"
SECOND = "22222222-2222-4222-8222-222222222222"
SPEC = importlib.util.spec_from_file_location("context_config_thread_test", SCRIPT)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class ThreadSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / "home"
        self.home.mkdir()
        self.root = Path(self.temporary.name) / "project"
        (self.root / ".codex").mkdir(parents=True)
        (self.root / ".codex/config.toml").write_text("model_context_window = 600000\n")
        (self.home / "config.toml").write_text(f'[projects.{json.dumps(str(self.root))}]\ntrust_level = "trusted"\n')
        self.project_before = (self.root / ".codex/config.toml").read_bytes()
        self.global_before = (self.home / "config.toml").read_bytes()

    def run_command(self, *arguments, check=True):
        result = subprocess.run([str(PYTHON), "-B", str(SCRIPT), *map(str, arguments)],
            env={**os.environ, "CODEX_HOME": str(self.home)}, capture_output=True, text=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        return result

    def test_custom_isolated_reset_and_preserved_configs(self):
        before = self.run_command("thread-status", self.root, FIRST)
        saved = self.run_command("thread-save", self.root, FIRST, "485", before["revision"], "custom")
        self.assertEqual(saved["window"], 485000)
        self.assertTrue(saved["override"])
        self.assertEqual(Path(saved["path"]).stat().st_mode & 0o777, 0o600)
        sibling = self.run_command("thread-status", self.root, SECOND)
        self.assertFalse(sibling["override"])
        self.assertIsNone(sibling["window"])
        self.assertEqual(self.run_command("thread-status", self.root, FIRST)["window"], 485000)
        conflict = self.run_command("thread-save", self.root, FIRST, "700", before["revision"], "custom", check=False)
        self.assertNotEqual(conflict.returncode, 0)
        reset = self.run_command("thread-save", self.root, FIRST, "", saved["revision"], "custom")
        self.assertFalse(reset["override"])
        self.assertEqual((self.root / ".codex/config.toml").read_bytes(), self.project_before)
        self.assertEqual((self.home / "config.toml").read_bytes(), self.global_before)

    def test_invalid_ids_and_symlink_do_not_write(self):
        self.assertNotEqual(self.run_command("thread-status", self.root, "../config", check=False).returncode, 0)
        directory = self.home / "context-menu/threads"
        directory.mkdir(parents=True)
        (directory / f"{FIRST}.json").symlink_to(self.home / "config.toml")
        self.assertNotEqual(self.run_command("thread-status", self.root, FIRST, check=False).returncode, 0)
        self.assertEqual((self.home / "config.toml").read_bytes(), self.global_before)

    def test_adaptive_and_untrusted_save_contract(self):
        with patch.dict(os.environ, {"CODEX_HOME": str(self.home)}), patch.object(backend, "adaptive_available", return_value=True):
            project = backend.status(self.root)
            current = backend.thread_status(project, FIRST, backend.read_config, backend.revision)
            saved = backend.save_thread(project, FIRST, "", current["revision"], "adaptive",
                backend.read_config, backend.revision, backend.parse_k)
            self.assertTrue(saved["adaptive"])
            self.assertTrue(saved["override"])
            self.assertIsNone(saved["window"])
            with self.assertRaises(ValueError):
                backend.save_thread({**project, "trusted": False}, FIRST, "485", saved["revision"], "custom",
                    backend.read_config, backend.revision, backend.parse_k)
            self.assertTrue(backend.thread_status(project, FIRST, backend.read_config, backend.revision)["adaptive"])


if __name__ == "__main__":
    unittest.main()
