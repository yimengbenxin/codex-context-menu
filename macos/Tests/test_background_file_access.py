import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

RESOURCES = Path(__file__).resolve().parents[1] / "Resources"


@unittest.skipUnless(sys.platform == "darwin", "macOS sandbox-exec acceptance")
class BackgroundFileAccessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve() / "home"
        self.codex = self.home / ".codex"
        self.project = self.home / "Documents" / "project"
        self.codex.mkdir(parents=True)
        self.project.mkdir(parents=True)
        self.parameters = {
            "HOME": self.home, "RESOURCES": RESOURCES,
            "CODEX_HOME": self.codex,
            "COST_CACHE": self.home / "Library/Caches/CodexBar",
            "CLI_CACHE": self.home / "Library/Caches/CodexBarCLI",
            "RUNTIME_CACHE": (Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()) / "CodexBarCLI").resolve(),
            "TEMPORARY": self.home / "tmp",
            "PREFERENCES": self.home / "Library/Preferences",
        }
        for name in ("COST_CACHE", "CLI_CACHE", "TEMPORARY", "PREFERENCES"):
            self.parameters[name].mkdir(parents=True)
        self.environment = {**os.environ, "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home), "CODEX_HOME": str(self.codex)}

    def run_sandbox(self, *command):
        arguments = ["/usr/bin/sandbox-exec"]
        for name, value in self.parameters.items():
            arguments += ["-D", f"{name}={value}"]
        arguments += ["-f", str(RESOURCES / "usage/cost-history.sb"), *map(str, command)]
        return subprocess.run(arguments, cwd=self.home, env=self.environment,
                              capture_output=True, text=True, timeout=60)

    def test_history_read_allowed_but_project_read_and_metadata_denied(self):
        history = self.codex / "sample.jsonl"
        history.write_text("local history")
        secret = self.project / "code.txt"
        secret.write_text("not statistics")
        self.assertEqual(self.run_sandbox("/bin/cat", history).stdout, "local history")
        self.assertNotEqual(self.run_sandbox("/bin/cat", secret).returncode, 0)
        self.assertNotEqual(self.run_sandbox("/usr/bin/stat", self.project).returncode, 0)

    def test_history_symlink_cannot_grant_project_access(self):
        secret = self.project / "code.txt"
        secret.write_text("not statistics")
        link = self.codex / "project-link"
        link.symlink_to(secret)
        self.assertNotEqual(self.run_sandbox("/bin/cat", link).returncode, 0)

    def test_native_provider_cold_and_incremental_token_totals(self):
        timestamp = datetime.now(timezone.utc).isoformat()
        sessions = self.codex / "sessions"
        sessions.mkdir()
        history = sessions / ("rollout-" + datetime.now().strftime("%Y-%m-%d") + "T00-00-00-00000000-0000-4000-8000-000000000001.jsonl")
        records = [
            {"type": "session_meta", "timestamp": timestamp, "payload": {
                "id": "00000000-0000-4000-8000-000000000001", "cwd": str(self.project), "source": "cli"}},
            {"type": "turn_context", "timestamp": timestamp, "payload": {"model": "gpt-5.4"}},
        ]

        def usage(input_tokens, output_tokens):
            value = {"input_tokens": input_tokens, "cached_input_tokens": 40,
                     "output_tokens": output_tokens, "reasoning_output_tokens": 0,
                     "total_tokens": input_tokens + output_tokens}
            return {"type": "event_msg", "timestamp": timestamp, "payload": {
                "type": "token_count", "info": {"total_token_usage": value, "last_token_usage": value}}}

        records.append(usage(100, 20))
        history.write_text("".join(json.dumps(record) + "\n" for record in records))
        command = [RESOURCES / "usage/CodexBarCLI", "cost", "--provider", "codex",
                   "--provider-native-only", "--days", "7", "--refresh", "--format", "json"]
        first = self.run_sandbox(*command)
        self.assertEqual(first.returncode, 0, first.stderr)
        report = json.loads(first.stdout)[0]
        self.assertNotIn("error", report)
        self.assertEqual(report["totals"]["inputTokens"], 100)
        self.assertEqual(report["totals"]["totalTokens"], 120)
        baseline = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", *map(str, command)],
                                  cwd=self.home, env=self.environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        original = json.loads(baseline.stdout)[0]
        self.assertEqual(report["daily"], original["daily"])
        self.assertEqual(report["totals"], original["totals"])
        with history.open("a") as output:
            output.write(json.dumps(usage(150, 30)) + "\n")
        second = self.run_sandbox(*command)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)[0]["totals"]["totalTokens"], 180)


if __name__ == "__main__":
    unittest.main()
