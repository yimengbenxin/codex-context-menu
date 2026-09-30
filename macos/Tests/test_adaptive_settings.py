import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[1] / "Resources"
SPEC = importlib.util.spec_from_file_location("adaptive_settings_backend_test", RESOURCES / "context_config.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
from adaptive_settings import options, overrides, from_project

FIRST = "11111111-1111-4111-8111-111111111111"


class AdaptiveSettingsTests(unittest.TestCase):
    def test_thresholds_and_tiers_are_validated(self):
        self.assertEqual(options()["lower_percent"], 35)
        self.assertEqual(options()["upper_percent"], 55)
        selected = options({"lower_percent": 30, "upper_percent": 50, "tiers": [272000, 485000, 872000]})
        self.assertEqual(selected["upper_percent"], 50)
        for value in [{"lower_percent": 60, "upper_percent": 50}, {"upper_percent": 101},
                      {"lower_percent": True}, {"tiers": [10, 9, 100]}, {"tiers": [0, None, None]}]:
            with self.assertRaises(ValueError):
                options(value)

    def test_default_values_are_not_stored_as_overrides_and_legacy_values_survive(self):
        self.assertEqual(overrides(options()), {})
        self.assertEqual(options(overrides(options())), options())
        legacy = {"lower_percent": 45, "upper_percent": 65}
        self.assertEqual(overrides(legacy), legacy)
        self.assertEqual(from_project({"codex_context_tool": legacy})["lower_percent"], 45)
        self.assertEqual(from_project({})["lower_percent"], 35)

    def exercise(self, thread):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            home = Path(temporary) / "home"
            home.mkdir()
            global_config = home / "config.toml"
            global_config.write_text(f'[projects.{json.dumps(str(root))}]\ntrust_level = "trusted"\n')
            before = global_config.read_bytes()
            selected = json.dumps({"lower_percent": 30, "upper_percent": 50, "tiers": [272000, 485000, 872000]})
            with patch.dict(os.environ, {"CODEX_HOME": str(home)}), patch.object(backend, "adaptive_status", return_value={"adaptive": True}):
                def status():
                    project = backend.status(root)
                    return backend.thread_status(project, FIRST, backend.read_config, backend.revision) if thread else project

                def save(mode, value=""):
                    current = status()
                    if thread:
                        return backend.save_thread(backend.status(root), FIRST, value, current["revision"], mode,
                            backend.read_config, backend.revision, backend.parse_k, selected)
                    return backend.save(root, value, current["revision"], mode, selected)

                adaptive = save("adaptive")
                self.assertEqual(adaptive["adaptive_options"]["tiers"], [272000, 485000, 872000])
                self.assertEqual(adaptive["adaptive_options"]["lower_percent"], 30)
                custom = save("custom", "600")
                self.assertEqual(custom["window"], 600000)
                returned = save("adaptive")
                self.assertNotEqual(adaptive["revision"], returned["revision"])
                self.assertTrue(returned["adaptive"])
                self.assertIsNone(returned["window"])
                self.assertEqual(status()["revision"], returned["revision"])
                self.assertEqual(global_config.read_bytes(), before)

    def test_project_policy_round_trip_changes_activation_revision(self):
        self.exercise(thread=False)

    def test_thread_policy_round_trip_is_persisted_and_resets_activation(self):
        self.exercise(thread=True)
