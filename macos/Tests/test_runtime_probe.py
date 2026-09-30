import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources"))
import runtime_probe


def schema(directory):
    (directory / "v2").mkdir()
    for name, fields in runtime_probe.CONTRACT.items():
        (directory / "v2" / f"{name}.json").write_text(json.dumps({"properties": dict.fromkeys(fields, {})}))
    (directory / "ClientRequest.json").write_text(json.dumps({"methods": ["config/read", "thread/read", "thread/resume", "thread/unsubscribe", "turn/start"]}))
    file = directory / "v2/ThreadTokenUsageUpdatedNotification.json"
    value = json.loads(file.read_text())
    value["definitions"] = {"Usage": {"properties": {"modelContextWindow": {}}}}
    file.write_text(json.dumps(value))


class RuntimeProbeTests(unittest.TestCase):
    def test_required_protocol_fields_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            schema(directory)
            runtime_probe.validate_schema(directory)
            (directory / "v2/ThreadResumeParams.json").write_text('{"properties":{"threadId":{}}}')
            with self.assertRaises(RuntimeError):
                runtime_probe.validate_schema(directory)

    def test_different_version_and_hash_are_accepted_only_with_signature_and_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary, node = root / "codex", root / "node"
            binary.write_bytes(b"official fixture 1590")
            node.write_bytes(b"node fixture")
            version = "0.159.0"

            def command(arguments, **kwargs):
                if "generate-json-schema" in arguments:
                    schema(Path(arguments[-1]))
                return subprocess.CompletedProcess(arguments, 0, stdout=f"codex-cli {version}", stderr=f"TeamIdentifier={runtime_probe.TEAM}\n")

            with patch.object(subprocess, "run", side_effect=command):
                first = runtime_probe.probe(binary, node)
                version = "0.159.2"
                binary.write_bytes(b"different official fixture 1592")
                second = runtime_probe.probe(binary, node)
            self.assertNotEqual(first["officialSha256"], second["officialSha256"])
            self.assertEqual(first["contract"], second["contract"])

    def test_other_developer_signature_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "codex"
            binary.write_bytes(b"fixture")
            with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="TeamIdentifier=OTHER\n")):
                with self.assertRaises(RuntimeError):
                    runtime_probe.probe(binary, binary)
