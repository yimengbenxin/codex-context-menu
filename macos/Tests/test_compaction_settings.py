import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[1] / "Resources"
SPEC = importlib.util.spec_from_file_location("compaction_backend", RESOURCES / "context_config.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
FIRST = "11111111-1111-4111-8111-111111111111"
SECOND = "22222222-2222-4222-8222-222222222222"


class CompactionSettingsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / "project"
        self.root.mkdir()
        self.home = Path(temporary.name) / "home"
        self.home.mkdir()
        (self.home / "config.toml").write_text(f'model = "fixture"\n[projects.{json.dumps(str(self.root))}]\ntrust_level = "trusted"\n')
        self.global_before = (self.home / "config.toml").read_bytes()
        (self.home / "models_cache.json").write_text(json.dumps({"models": [{"slug": "fixture", "context_window": 272000,
            "max_context_window": 872000, "effective_context_window_percent": 95}]}))
        with sqlite3.connect(self.home / "state_5.sqlite") as connection:
            connection.execute("CREATE TABLE threads(id TEXT, cwd TEXT, model TEXT)")
            connection.executemany("INSERT INTO threads VALUES(?, ?, ?)", [(identifier, str(self.root), "fixture") for identifier in [FIRST, SECOND]])
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"CODEX_HOME": str(self.home)}).start()
        patch.object(backend, "adaptive_status", return_value={"adaptive": True}).start()

    def project(self):
        return backend.status(self.root)

    def test_project_round_trip_and_safety_rejection_are_atomic(self):
        selected = json.dumps({"compaction_percent": 99})
        saved = backend.save(self.root, "272", self.project()["revision"], "custom", selected)
        self.assertEqual(saved["compaction_percent"], 99)
        self.assertEqual(saved["window"], 272000)
        before = Path(saved["path"]).read_bytes()
        with self.assertRaisesRegex(ValueError, "最多允许 90"):
            backend.save(self.root, "870", saved["revision"], "custom", json.dumps({"compaction_percent": 95}))
        self.assertEqual(Path(saved["path"]).read_bytes(), before)
        for percent in [100, 0, 95.5, True]:
            with self.assertRaises(ValueError):
                backend.save(self.root, "272", saved["revision"], "custom", json.dumps({"compaction_percent": percent}))
        reset = backend.save(self.root, "272", saved["revision"], "custom", json.dumps({"compaction_percent": None}))
        self.assertIsNone(reset["compaction_percent"])
        self.assertEqual((self.home / "config.toml").read_bytes(), self.global_before)

    def test_thread_only_compression_can_inherit_the_context_budget(self):
        current = backend.thread_status(self.project(), FIRST, backend.read_config, backend.revision)
        saved = backend.save_thread(self.project(), FIRST, "", current["revision"], "default", backend.read_config,
            backend.revision, backend.parse_k, json.dumps({"compaction_percent": 95}))
        self.assertEqual(saved["compaction_percent"], 95)
        self.assertFalse(saved["override"])
        self.assertIsNone(saved["window"])
        sibling = backend.thread_status(self.project(), SECOND, backend.read_config, backend.revision)
        self.assertIsNone(sibling["compaction_percent"])
        self.assertFalse((self.root / ".codex/config.toml").exists())

    def test_percentage_change_preserves_the_adaptive_budget_revision(self):
        selected = json.dumps({"compaction_percent": 95})
        adaptive = backend.save(self.root, "", self.project()["revision"], "adaptive")
        changed = backend.save(self.root, "", adaptive["revision"], "adaptive", selected)
        self.assertNotEqual(changed["revision"], adaptive["revision"])
        self.assertEqual(changed["budget_revision"], adaptive["budget_revision"])


if __name__ == "__main__":
    unittest.main()
