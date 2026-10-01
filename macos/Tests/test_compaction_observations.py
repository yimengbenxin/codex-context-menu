import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

FILE = Path(__file__).resolve().parents[1] / "Resources/compaction_observations.py"
SPEC = importlib.util.spec_from_file_location("observations", FILE)
observations = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observations)


class CompactionObservationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)

    def row(self, index, **changes):
        return {"id": str(index), "project": hashlib.sha256(b"/project").hexdigest(), "thread": "first", "model": "fixture",
            "budget": 272000, "percent": 95, "scope": "body_after_prefix", "target": 258400,
            "before_input": 258400, "before_total": 258400, "after_total": 90000, "usage_age_ms": 2,
            "manual": False, "status": "completed", "at": index, "duration_ms": 35000, **changes}

    def report(self, thread="first"):
        return observations.report(self.home, "/project", thread, "fixture", 272000, 99)

    def test_empirical_rate_recommendation_and_no_content_storage(self):
        for index in range(10):
            observations.record(self.home, self.row(index, before_total=277000 if index < 3 else 260000))
        group = self.report()["groups"][0]
        self.assertEqual(group["observed_rate"], .3)
        self.assertEqual(group["mean_excess"], 5000)
        self.assertEqual(group["p95_excess"], 5000)
        self.assertEqual(group["recommended_percent"], 93)
        self.assertEqual(self.report()["recent"][0]["before_input"], 258400)
        with self.assertRaises(ValueError):
            observations.record(self.home, {**self.row(11), "chat_text": "never save this"})
        self.assertEqual(observations.database_path(self.home).stat().st_mode & 0o777, 0o600)

    def test_unknown_manual_failed_and_default_are_not_negative_observations(self):
        rows = [self.row(0), self.row(1, before_total=None), self.row(2, manual=True), self.row(3, status="failed"),
            self.row(4, percent=None, target=None)]
        for row in rows:
            observations.record(self.home, row)
        groups = self.report()["groups"]
        selected = next(group for group in groups if group["percent"] == 95)
        self.assertEqual((selected["automatic"], selected["measured"], selected["unknown"], selected["manual"], selected["failed"]), (2, 1, 1, 1, 1))
        self.assertEqual(selected["observed_rate"], 0)
        self.assertIsNone(selected["recommended_percent"])
        self.assertEqual(next(group for group in groups if group["percent"] is None)["observed_rate"], 0)
        self.assertIsNone(next(group for group in groups if group["percent"] is None)["recommended_percent"])

    def test_groups_and_target_scope_are_separate(self):
        for index, changes in enumerate([{}, {"thread": "second"}, {"percent": 90}, {"scope": "total"},
            {"model": "other"}, {"budget": 485000}, {"project": "other"}]):
            observations.record(self.home, self.row(index, **changes))
        self.assertEqual(sum(group["samples"] for group in self.report()["groups"]), 3)
        self.assertEqual(sum(group["samples"] for group in self.report(None)["groups"]), 4)

    def test_deduplication_concurrent_writers_and_reopen(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as workers:
            list(workers.map(lambda index: observations.record(self.home, self.row(index % 10)), range(30)))
        self.assertEqual(self.report()["groups"][0]["samples"], 10)
        with sqlite3.connect(observations.database_path(self.home)) as connection:
            self.assertEqual(connection.execute("PRAGMA quick_check").fetchone()[0], "ok")

    def test_bad_database_and_symbolic_link_do_not_modify_target(self):
        file = observations.database_path(self.home)
        file.parent.mkdir()
        file.write_bytes(b"broken")
        self.assertIn("error", self.report())
        file.unlink()
        target = self.home / "preserve"
        target.write_bytes(b"untouched")
        file.symlink_to(target)
        with self.assertRaises(ValueError):
            observations.record(self.home, self.row(0))
        self.assertIn("error", self.report())
        self.assertEqual(target.read_bytes(), b"untouched")

    def test_recommendation_respects_maximum_and_coverage(self):
        rows = [self.row(index) for index in range(10)]
        self.assertEqual(observations.summarize(rows, 90)[0]["recommended_percent"], 90)
        rows.extend(self.row(index, before_total=None) for index in range(10, 15))
        self.assertIsNone(observations.summarize(rows, 99)[0]["recommended_percent"])
        normal = observations.summarize([self.row(index, before_total=270000) for index in range(10)], 99)[0]
        self.assertEqual(normal["trigger_crossed"], 10)
        self.assertEqual(normal["crossed"], 0)
        self.assertEqual(normal["recommended_percent"], 95)

    def test_cross_process_writers_share_one_database(self):
        environment = {**os.environ, "CODEX_HOME": str(self.home)}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(lambda index: subprocess.run([sys.executable, "-B", str(FILE), "record", json.dumps(self.row(index))],
                env=environment, capture_output=True, text=True, check=True), range(8)))
        self.assertEqual(self.report()["groups"][0]["samples"], 8)

    def test_retention_is_bounded_and_invalid_numbers_are_rejected(self):
        observations.record(self.home, self.row(0))
        with sqlite3.connect(observations.database_path(self.home)) as connection:
            connection.executemany("INSERT INTO samples VALUES(?,?,?,?,?,?,?)", [
                (str(index), self.row(index)["project"], "first", "fixture", 272000, index, json.dumps(self.row(index)))
                for index in range(1, 10005)])
        observations.record(self.home, self.row(10005))
        with sqlite3.connect(observations.database_path(self.home)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM samples").fetchone()[0], 10000)
            self.assertEqual(connection.execute("SELECT min(at) FROM samples").fetchone()[0], 6)
        for change in ({"before_total": -1}, {"before_total": True}, {"at": None}, {"duration_ms": None}, {"percent": 100}):
            with self.assertRaises(ValueError):
                observations.record(self.home, self.row(10006, **change))
