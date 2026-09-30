import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "Resources/context_config.py"
SPEC = importlib.util.spec_from_file_location("context_config", SCRIPT)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class ContextConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "项目 with spaces"
        self.root.mkdir()
        self.home = Path(self.temporary.name) / "isolated-home"
        self.home.mkdir()
        self.global_path = self.home / "config.toml"
        self.global_path.write_text('[projects.' + json.dumps(str(self.root), ensure_ascii=False) + ']\ntrust_level = "trusted"\n')
        self.original_global = self.global_path.read_bytes()
        self.environment = patch.dict(os.environ, {"CODEX_HOME": str(self.home)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.config = self.root / ".codex/config.toml"

    def store(self, text):
        self.config.parent.mkdir(exist_ok=True)
        self.config.write_text(text)

    def test_custom_and_default_preserve_other_settings(self):
        self.store('# keep this comment\nmodel = "dynamic-model"\nmodel_auto_compact_token_limit = 100\n[mcp_servers.local]\ncommand = "echo"\n')
        current = backend.status(self.root)
        custom = backend.save(self.root, "485K", current["revision"])
        self.assertEqual(custom["window"], 485000)
        self.assertIsNone(custom["compact"])
        self.assertIn("# keep this comment", self.config.read_text())
        self.assertEqual(tomllib.loads(self.config.read_text())["mcp_servers"]["local"]["command"], "echo")
        restored = backend.save(self.root, "", custom["revision"])
        self.assertIsNone(restored["window"])
        self.assertNotIn("272000", self.config.read_text())
        self.assertEqual(self.global_path.read_bytes(), self.original_global)
        self.assertEqual(len(list((self.config.parent / "context-menu-backups").glob("*.toml"))), 2)

    def test_custom_empty_and_validation(self):
        self.assertIsNone(backend.parse_k("  "))
        for value in ["0", "-1", "1.5", "485M", "abc", str(2**63)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                backend.parse_k(value)
        self.assertEqual(backend.parse_k(" 485k "), 485000)

    def test_default_without_existing_config_creates_no_files(self):
        current = backend.status(self.root)
        saved = backend.save(self.root, "", current["revision"])
        self.assertIsNone(saved["window"])
        self.assertFalse(self.config.parent.exists())

    def test_rejects_stale_revision_without_overwriting(self):
        initial = backend.status(self.root)
        self.store('model = "concurrent-change"\n')
        with self.assertRaises(ValueError):
            backend.save(self.root, "485", initial["revision"])
        self.assertEqual(self.config.read_text(), 'model = "concurrent-change"\n')

    def test_rejects_symlink_and_untrusted_project(self):
        self.config.parent.symlink_to(self.home, target_is_directory=True)
        with self.assertRaises(ValueError):
            backend.status(self.root)
        self.config.parent.unlink()
        self.global_path.write_text("")
        current = backend.status(self.root)
        with self.assertRaises(ValueError):
            backend.save(self.root, "485", current["revision"])
        self.assertFalse(self.config.exists())

    def test_child_untrusted_overrides_trusted_parent(self):
        child = self.root / "child"
        child.mkdir()
        with self.global_path.open("a") as output:
            output.write('[projects.' + json.dumps(str(child)) + ']\ntrust_level = "untrusted"\n')
        self.assertFalse(backend.status(child)["trusted"])

    def test_reports_inherited_overrides(self):
        self.global_path.write_text("model_context_window = 600000\n" + self.original_global.decode())
        current = backend.status(self.root)
        self.assertEqual(current["inherited"][0]["values"]["model_context_window"], 600000)

    def test_cli_process_roundtrip(self):
        command = [sys.executable, str(SCRIPT)]
        current = json.loads(subprocess.check_output(command + ["status", str(self.root)]))
        saved = json.loads(subprocess.check_output(command + ["save", str(self.root), "485", current["revision"]]))
        self.assertEqual(saved["window"], 485000)
        restored = json.loads(subprocess.check_output(command + ["save", str(self.root), "", saved["revision"]]))
        self.assertIsNone(restored["window"])

    def test_three_modes_clear_only_owned_keys(self):
        self.store('model_context_window = 485000\n[features]\nremote_compaction_v2 = true\n')
        with patch.object(backend, "adaptive_status", return_value={"adaptive": True}):
            current = backend.status(self.root)
            adaptive = backend.save(self.root, "invalid ignored input", current["revision"], "adaptive")
            self.assertTrue(adaptive["adaptive"])
            self.assertIsNone(adaptive["window"])
            custom = backend.save(self.root, "485", adaptive["revision"], "custom")
            self.assertFalse(custom["adaptive"])
            restored = backend.save(self.root, "", custom["revision"], "custom")
            self.assertFalse(restored["adaptive"])
            self.assertIsNone(restored["window"])
            values = tomllib.loads(self.config.read_text())
            self.assertTrue(values["features"]["remote_compaction_v2"])
            self.assertEqual(self.global_path.read_bytes(), self.original_global)

    def test_unverified_adaptive_does_not_write(self):
        current = backend.status(self.root)
        with patch.object(backend, "adaptive_status", return_value={"adaptive": False}), self.assertRaises(ValueError):
            backend.save(self.root, "", current["revision"], "adaptive")
        self.assertFalse(self.config.exists())

    def test_adaptive_conflicts_preserve_existing_settings(self):
        self.store('[features]\ntoken_budget = true\n')
        original = self.config.read_bytes()
        with patch.object(backend, "adaptive_status", return_value={"adaptive": True}), self.assertRaises(ValueError):
            backend.save(self.root, "", backend.status(self.root)["revision"], "adaptive")
        self.assertEqual(self.config.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
