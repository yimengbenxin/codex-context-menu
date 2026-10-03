import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "Resources/context_config.py"
SPEC = importlib.util.spec_from_file_location("context_config", SCRIPT)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
BINARY = os.environ.get("CODEX_CONTEXT_TEST_BINARY", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
MODEL = "gpt-6.1-sol"
requests = []


class MockResponses(BaseHTTPRequestHandler):
    def log_message(self, *_arguments):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append({"path": self.path, "model": body.get("model")})
        events = [
            {"type": "response.created", "response": {"id": "test-response"}},
            {"type": "response.output_item.done", "item": {"type": "message", "role": "assistant", "id": "test-message", "content": [{"type": "output_text", "text": "OK"}]}},
            {"type": "response.completed", "response": {"id": "test-response", "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11}}},
        ]
        payload = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="codex-context-runtime-") as temporary:
        root = Path(temporary)
        project = root / "project"
        project.mkdir()
        home = root / "home"
        codex_home = home / ".codex"
        codex_home.mkdir(parents=True)
        catalog = root / "catalog.json"
        cache = json.loads((Path.home() / ".codex/models_cache.json").read_text())
        model = next(entry for entry in cache["models"] if entry["slug"] == MODEL)
        model["model_messages"] = None
        model["base_instructions"] = "Return OK."
        model["context_window"] = 333000
        catalog.write_text(json.dumps({"models": [model]}))
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockResponses)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        configuration = f'''model = "{MODEL}"
    model_provider = "local-test"
    model_catalog_json = {json.dumps(str(catalog))}
    [model_providers.local-test]
    name = "Local isolated test"
    base_url = "http://127.0.0.1:{server.server_port}/v1"
    wire_api = "responses"
    requires_openai_auth = false
    supports_websockets = false
    request_max_retries = 0
    stream_max_retries = 0
    [projects.{json.dumps(str(project))}]
    trust_level = "trusted"
    '''
        (codex_home / "config.toml").write_text(configuration)
        environment = {"HOME": str(home), "CODEX_HOME": str(codex_home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporary, "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1"}
        results = []

        def run_turn(label, expected, target=None):
            before = set(codex_home.glob("sessions/**/*.jsonl"))
            completed = subprocess.run([BINARY, "exec", "--json", "--skip-git-repo-check", "-C", str(project), "Return OK."], env=environment, capture_output=True, text=True, timeout=45)
            if completed.returncode:
                raise RuntimeError(completed.stderr + completed.stdout)
            paths = set(codex_home.glob("sessions/**/*.jsonl")) - before
            assert len(paths) == 1, paths
            records = [json.loads(line) for line in next(iter(paths)).read_text().splitlines()]
            windows = [record["payload"].get("info", {}).get("model_context_window") for record in records if record["type"] == "event_msg" and record["payload"].get("type") == "token_count" and record["payload"].get("info")]
            assert expected in windows, (label, windows, completed.stdout, completed.stderr)
            targets = [record["payload"]["info"].get("target_context_budget_tokens") for record in records if record["type"] == "event_msg" and record["payload"].get("type") == "token_count" and record["payload"].get("info")]
            assert target in targets, (label, targets)
            results.append({"mode": label, "runtime_window": expected, "model": MODEL})
            time.sleep(0.02)

        try:
            with patch.dict(os.environ, {"CODEX_HOME": str(codex_home)}):
                run_turn("catalog_default_333k", 316350)
                current = backend.status(project)
                backend.save(project, "485", current["revision"])
                run_turn("custom_485k", 460750)
                current = backend.status(project)
                backend.save(project, "", current["revision"])
                model["context_window"] = 350000
                catalog.write_text(json.dumps({"models": [model]}))
                run_turn("reset_follows_changed_catalog_350k", 332500)
                if os.environ.get("CODEX_CONTEXT_TEST_ADAPTIVE"):
                    with patch.object(backend, "adaptive_available", return_value=True):
                        current = backend.status(project)
                        backend.save(project, "", current["revision"], "adaptive")
                        model["max_context_window"] = 900000
                        catalog.write_text(json.dumps({"models": [model]}))
                        run_turn("adaptive_uses_default_350k_and_max_900k", 855000, 350000)
                        model["context_window"] = 400000
                        model["max_context_window"] = 1200000
                        catalog.write_text(json.dumps({"models": [model]}))
                        run_turn("new_adaptive_session_follows_changed_catalog", 1140000, 400000)
                        current = backend.status(project)
                        backend.save(project, "", current["revision"], "custom")
                        run_turn("blank_custom_leaves_adaptive_for_official_default", 380000)
            assert (codex_home / "config.toml").read_text() == configuration
            assert len(requests) == len(results), requests
            print(json.dumps({"result": "PASS", "real_official_binary": BINARY, "model_responses": "local mock only; no credentials", "turns": results, "requests": requests}, indent=2))
        finally:
            server.shutdown()
