import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[1] / "Resources"
SPEC = importlib.util.spec_from_file_location("preview_backend_test", RESOURCES / "context_config.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
import adaptive_preview

THREAD = "11111111-1111-4111-8111-111111111111"


class AdaptivePreviewTests(unittest.TestCase):
    def test_preview_entrypoint_resolves_package_path_alias(self):
        with tempfile.TemporaryDirectory() as temporary:
            alias = Path(temporary) / "resources-alias"
            alias.symlink_to(RESOURCES, target_is_directory=True)
            catalog = {"models": [{"slug": "alias-fixture", "context_window": 272000,
                "max_context_window": 872000, "effective_context_window_percent": 95}]}
            result = subprocess.run([shutil.which("node"), str(alias / "adaptive/policy.mjs"), "--preview"],
                input=json.dumps({"catalog": catalog, "model": "alias-fixture"}),
                capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)["compaction"]["budget"], 272000)

    def test_preview_without_shell_home_uses_system_home(self):
        environment = {key: value for key, value in os.environ.items() if key not in ("HOME", "CODEX_HOME")}
        catalog = {"models": [{"slug": "preview-no-home-fixture", "context_window": 272000,
            "max_context_window": 872000, "effective_context_window_percent": 95}]}
        result = subprocess.run([shutil.which("node"), str(RESOURCES / "adaptive/policy.mjs"), "--preview"],
            input=json.dumps({"catalog": catalog, "model": "preview-no-home-fixture", "settings": {"root": "/preview-fixture"}}),
            capture_output=True, text=True, env=environment, check=True)
        self.assertEqual(json.loads(result.stdout)["compaction"]["maximum_percent"], 99)

    def test_exact_thread_model_takes_precedence_and_index_remains_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "config.toml").write_text('model = "other"')
            database = sqlite3.connect(home / "state_5.sqlite")
            database.execute("CREATE TABLE threads (id TEXT, cwd TEXT, model TEXT)")
            database.execute("INSERT INTO threads VALUES (?, ?, ?)", (THREAD, "/project", "fixture"))
            database.commit()
            database.close()
            before = (home / "state_5.sqlite").read_bytes()
            self.assertEqual(adaptive_preview.selected_model(home, Path("/project"), THREAD), "fixture")
            with self.assertRaises(ValueError):
                adaptive_preview.selected_model(home, Path("/wrong"), THREAD)
            self.assertEqual((home / "state_5.sqlite").read_bytes(), before)

    def test_preview_reuses_policy_and_missing_metadata_does_not_break_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "config.toml").write_text('model = "fixture"')
            catalog = {"models": [{"slug": "fixture", "context_window": 300000, "max_context_window": 900000,
                "effective_context_window_percent": 95}]}
            (home / "models_cache.json").write_text(json.dumps(catalog))
            with patch.dict(os.environ, {"CODEX_HOME": str(home)}), patch.object(adaptive_preview.runtime_probe, "discover", return_value=("cli", "node")), \
                    patch.object(adaptive_preview.runtime_probe, "verify_identity", return_value=("cli", shutil.which("node"))):
                result = adaptive_preview.preview_status({"root": str(home)})
                self.assertEqual(result["adaptive_preview"]["tiers"], [300000, 600000, 900000])
                self.assertEqual(result["adaptive_preview"]["display_tiers"], [300000, 600000, 900000])
                self.assertEqual(result["adaptive_preview"]["thresholds"], {"lower": .35, "upper": .55})
                catalog["models"][0]["max_context_window"] = 300000
                (home / "models_cache.json").write_text(json.dumps(catalog))
                collapsed = adaptive_preview.preview_status({"root": str(home)})["adaptive_preview"]
                self.assertEqual(collapsed["display_tiers"], [300000, 300000, 300000])
                (home / "models_cache.json").write_text('{"models":[]}')
                self.assertIn("adaptive_preview_reason", adaptive_preview.preview_status({"root": str(home)}))

    def test_defaults_persist_as_implicit_project_and_thread_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            home.mkdir()
            project = Path(temporary) / "project"
            project.mkdir()
            (home / "config.toml").write_text(f'[projects.{json.dumps(str(project))}]\ntrust_level = "trusted"\n')
            with patch.dict(os.environ, {"CODEX_HOME": str(home)}), patch.object(backend, "adaptive_status", return_value={"adaptive": True}):
                current = backend.status(project)
                saved = backend.save(project, "", current["revision"], "adaptive", json.dumps(current["adaptive_defaults"]))
                self.assertNotIn("lower_percent", Path(saved["path"]).read_text())
                current = backend.thread_status(saved, THREAD, backend.read_config, backend.revision)
                thread = backend.save_thread(saved, THREAD, "", current["revision"], "adaptive", backend.read_config,
                    backend.revision, backend.parse_k, json.dumps(saved["adaptive_defaults"]))
                self.assertEqual(json.loads(Path(thread["path"]).read_text())["adaptive_options"], {})
                self.assertEqual(thread["adaptive_options"]["lower_percent"], 35)
