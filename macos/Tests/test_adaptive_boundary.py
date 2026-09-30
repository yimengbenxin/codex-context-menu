import asyncio
import json
import os
from pathlib import Path
import tempfile
import sqlite3
import sys
import hashlib
from aiohttp import web, WSMsgType

ROOT = Path(__file__).resolve().parents[2]
NODE = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
PYTHON = Path(os.environ.get("CODEX_TEST_PYTHON", sys.executable))
OUTPUT = Path(os.environ.get("CODEX_CONTEXT_TEST_OUTPUT", str(ROOT / "artifacts/official-adaptive-boundary.json")))
RESOURCES = Path(os.environ.get("CODEX_CONTEXT_TEST_RESOURCES", str(ROOT / "macos/Resources")))
MODEL = "gpt-6.1-sol"
captured = []
force_large_turns = 0
force_large_tokens = 260000


def events(body):
    global force_large_turns
    compact = any(item.get("type") == "compaction_trigger" for item in body.get("input", []))
    metadata = body.get("client_metadata") or {}
    purpose = json.loads(metadata.get("x-codex-turn-metadata", "{}"))
    kind = purpose.get("request_kind")
    captured.append({"model": body.get("model"), "reasoning": body.get("reasoning"),
                     "compact": compact, "kind": kind,
                     "input_types": [item.get("type") for item in body.get("input", [])]})
    item = {"type": "compaction", "encrypted_content": "ISOLATED_CHECKPOINT"} if compact else {
        "id": "fixture-message", "type": "message", "role": "assistant", "status": "completed",
        "content": [{"type": "output_text", "text": "OK", "annotations": []}]}
    ordinary_count = sum(request["kind"] == "turn" and not request["compact"] for request in captured)
    tokens = 260000 if ordinary_count == 1 and kind == "turn" and not compact else 190000
    if force_large_turns and kind == "turn" and not compact:
        tokens = force_large_tokens
        force_large_turns -= 1
    return [
        {"type": "response.created", "response": {"id": "fixture-response"}},
        {"type": "response.output_item.done", "output_index": 0, "item": item},
        {"type": "response.completed", "response": {"id": "fixture-response", "status": "completed",
            "output": [item], "usage": {"input_tokens": tokens, "output_tokens": 5, "total_tokens": tokens + 5}}},
    ]


async def mock(request):
    if request.headers.get("Upgrade", "").lower() == "websocket":
        socket = web.WebSocketResponse()
        await socket.prepare(request)
        async for message in socket:
            if message.type == WSMsgType.TEXT:
                for event in events(json.loads(message.data)):
                    await socket.send_json(event)
        return socket
    body = await request.json()
    payload = "".join("data: " + json.dumps(event) + "\n\n" for event in events(body))
    return web.Response(text=payload, content_type="text/event-stream")


class Rpc:
    def __init__(self, process):
        self.process = process
        self.number = 0
        self.events = []
        self.observed = []

    async def receive(self):
        line = await asyncio.wait_for(self.process.stdout.readline(), 40)
        if not line:
            raise RuntimeError("Candidate exited before replying")
        value = json.loads(line)
        if value.get("method") in ("item/completed", "thread/tokenUsage/updated"):
            self.observed.append(value)
        if value.get("method") == "error":
            raise RuntimeError(str(value["params"]))
        return value

    async def request(self, method, params):
        self.number += 1
        self.process.stdin.write((json.dumps({"id": self.number, "method": method, "params": params}) + "\n").encode())
        await self.process.stdin.drain()
        while True:
            message = await self.receive()
            if message.get("id") == self.number:
                if "error" in message:
                    raise RuntimeError(str(message["error"]))
                return message["result"]
            self.events.append(message)

    async def turn(self, thread):
        await self.request("turn/start", {"threadId": thread, "effort": "high", "input": [
            {"type": "text", "text": "Return OK, no tools. This is an isolated protocol fixture."}]})
        usage = None
        while True:
            message = self.events.pop(0) if self.events else await self.receive()
            if message.get("method") == "thread/tokenUsage/updated":
                usage = message["params"]["tokenUsage"]
            if message.get("method") == "turn/completed":
                assert message["params"]["turn"]["status"] == "completed", message
                assert usage is not None
                return usage["modelContextWindow"]


async def run():
    global force_large_turns, force_large_tokens
    result = {"passed": False, "scope": "signed official runtime with local synthetic responses",
              "main_modified": False, "desktop_tools_tested": False, "real_quality_tested": False}
    application = web.Application()
    application.router.add_route("*", "/{tail:.*}", mock)
    server = web.AppRunner(application, access_log=None)
    await server.setup()
    site = web.TCPSite(server, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    process = None
    with tempfile.TemporaryDirectory(prefix="official-adaptive-boundary-", ignore_cleanup_errors=True) as temporary:
        directory = Path(temporary).resolve()
        home = directory / "home/.codex"
        home.mkdir(parents=True)
        project = directory / "project"
        (project / ".codex").mkdir(parents=True)
        (project / ".codex/config.toml").write_text("[features]\nadaptive_context_budget = true\n")
        cache_bytes = (Path.home() / ".codex/models_cache.json").read_bytes()
        (home / "models_cache.json").write_bytes(cache_bytes)
        catalog = directory / "official-catalog.json"
        catalog.write_text(json.dumps({"models": json.loads(cache_bytes)["models"]}))
        selected = next(model for model in json.loads(cache_bytes)["models"] if model["slug"] == MODEL)
        default = selected["context_window"]
        middle = (default + selected["max_context_window"]) // 2
        percent = selected["effective_context_window_percent"]
        result["official_metadata"] = {"default": default, "middle": middle, "percent": percent}
        (home / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "local-fixture-only"}))
        (home / "config.toml").write_text(f'''model = "{MODEL}"
model_catalog_json = {json.dumps(str(catalog))}
web_search = "disabled"
[features]
remote_compaction_v2 = true
[projects.{json.dumps(str(project))}]
trust_level = "trusted"
''')
        environment = {"HOME": str(directory / "home"), "CODEX_HOME": str(home),
            "CODEX_CONTEXT_OFFICIAL_BINARY": os.environ.get("CODEX_CONTEXT_TEST_BINARY", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            "CODEX_CONTEXT_PYTHON": str(PYTHON), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporary, "NO_PROXY": "localhost,127.0.0.1,::1"}
        support = directory / "home/Library/Application Support/CodexContextTool"
        support.mkdir(parents=True)
        adaptive = RESOURCES / "adaptive"
        files = {os.path.relpath(file, adaptive): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in [*adaptive.glob("*"), RESOURCES / "context_config.py", RESOURCES / "thread_settings.py", RESOURCES / "adaptive_settings.py"] if file.is_file()}
        manifest = {"accepted": True, "contract": "round-boundary-v1", "files": files, "python": str(PYTHON),
            "binary": environment["CODEX_CONTEXT_OFFICIAL_BINARY"], "node": NODE,
            "officialSha256": hashlib.sha256(Path(environment["CODEX_CONTEXT_OFFICIAL_BINARY"]).read_bytes()).hexdigest(),
            "nodeSha256": hashlib.sha256(Path(NODE).read_bytes()).hexdigest()}
        (support / "official-adaptive-runtime.json").write_text(json.dumps(manifest))
        (support / "backend").symlink_to(adaptive / "backend")
        with OUTPUT.with_suffix(".stderr.log").open("wb") as log:
            async def start():
                nonlocal process
                process = await asyncio.create_subprocess_exec(NODE,
                    str(RESOURCES / "adaptive/boundary.mjs"),
                    *json.loads(os.environ.get("CODEX_CONTEXT_TEST_SERVER_ARGS", "[]")),
                    "-c", f'openai_base_url="http://127.0.0.1:{port}/v1"',
                    "app-server", env=environment, cwd=project, stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE, stderr=log, limit=8 * 1024 * 1024)
                rpc = Rpc(process)
                await rpc.request("initialize", {"clientInfo": {"name": "official-adaptive-fixture", "version": "1.0"},
                    "capabilities": {"experimentalApi": True}})
                process.stdin.write(b'{"method":"initialized","params":{}}\n')
                return rpc

            async def stop():
                nonlocal process
                if process:
                    process.stdin.close()
                    await asyncio.wait_for(process.wait(), 20)
                    process = None

            try:
                rpc = await start()
                created = await rpc.request("thread/start", {"model": MODEL, "cwd": str(project),
                    "approvalPolicy": "never", "sandbox": os.environ.get("CODEX_CONTEXT_TEST_SANDBOX", "read-only")})
                thread = created["thread"]["id"]
                result["created"] = created
                windows = [await rpc.turn(thread) for _ in range(2)]
                history = Path(created["thread"]["path"])
                history_before = history.read_bytes()
                windows.append(await rpc.turn(thread))
                assert history.read_bytes().startswith(history_before), "Existing rollout records changed during reload"
                result["history_prefix_preserved"] = True
                result["observed"] = rpc.observed
                await stop()
                rpc = await start()
                await rpc.request("thread/resume", {"threadId": thread})
                windows.append(await rpc.turn(thread))
                assert history.read_bytes().startswith(history_before), "Existing rollout records changed during restart"
                forked = await rpc.request("thread/fork", {"threadId": thread})
                windows.append(await rpc.turn(forked["thread"]["id"]))
                result["fork_budget_preserved"] = windows[-1] == middle * percent // 100
                for database in home.glob("state_*.sqlite"):
                    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
                        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                result["database_integrity"] = True
                result["windows"] = windows
                result["requests"] = captured
                state = home / "adaptive-context/budgets.json"
                result["state"] = json.loads(state.read_text()) if state.exists() else None
                assert windows == [default * percent // 100, default * percent // 100,
                                   middle * percent // 100, middle * percent // 100, middle * percent // 100], windows
                assert any(request["compact"] for request in captured), captured
                assert all(request["model"] == MODEL for request in captured)
                assert all(request["reasoning"]["effort"] == "high" for request in captured if request["kind"] != "prewarm")
                assert "compaction" in captured[-1]["input_types"], captured[-1]
                project_config = project / ".codex/config.toml"
                changes = []
                for label, document, expected in [
                    ("custom_485k", "model_context_window = 485000\n", 485000 * percent // 100),
                    ("default", "", default * percent // 100),
                    ("custom_above_maximum", "model_context_window = 999000\n", selected["max_context_window"] * percent // 100),
                    ("blank_custom_is_default", "", default * percent // 100),
                    ("adaptive_again_restores_saved_tier", "[features]\nadaptive_context_budget = true\n", middle * percent // 100),
                ]:
                    project_config.write_text(document)
                    merged = await rpc.request("config/read", {"cwd": str(project), "includeLayers": False})
                    actual = await rpc.turn(thread)
                    changes.append({"mode": label, "expected": expected, "observed": actual,
                                    "native_override": merged["config"].get("model_context_window")})
                    assert actual == expected, changes
                project_config.write_text("")
                global_config = home / "config.toml"
                global_config.write_text("model_context_window = 350000\n" + global_config.read_text())
                actual = await rpc.turn(thread)
                changes.append({"mode": "default_inherits_global", "observed": actual, "expected": 350000 * percent // 100})
                assert actual == 350000 * percent // 100, changes
                assert history.read_bytes().startswith(history_before), "History changed during mode switches"
                for database in home.glob("state_*.sqlite"):
                    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
                        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                result["next_turn_modes"] = changes
                result["mode_switch_process_unchanged"] = process.returncode is None
                private_directory = home / "context-menu/threads"
                private_directory.mkdir(parents=True)
                private = private_directory / f"{thread}.json"
                private.write_text(json.dumps({"root": str(project), "thread": thread, "mode": "custom", "window": 485000}))
                project_config.write_text("model_context_window = 600000\n")
                assert await rpc.turn(thread) == 485000 * percent // 100
                sibling = await rpc.request("thread/start", {"model": MODEL, "cwd": str(project),
                    "approvalPolicy": "never", "sandbox": "read-only"})
                sibling_id = sibling["thread"]["id"]
                assert await rpc.turn(sibling_id) == 600000 * percent // 100
                forked_private = await rpc.request("thread/fork", {"threadId": thread})
                assert await rpc.turn(forked_private["thread"]["id"]) == 600000 * percent // 100
                await stop()
                rpc = await start()
                await rpc.request("thread/resume", {"threadId": thread})
                assert await rpc.turn(thread) == 485000 * percent // 100
                private.unlink()
                assert await rpc.turn(thread) == 600000 * percent // 100
                project_before = project_config.read_bytes()
                sibling_private = private_directory / f"{sibling_id}.json"
                sibling_private.write_text(json.dumps({"root": str(project), "thread": sibling_id, "mode": "adaptive", "window": None}))
                force_large_turns = 1
                private_windows = [await rpc.turn(sibling_id) for _ in range(3)]
                assert private_windows == [default * percent // 100, default * percent // 100, middle * percent // 100], private_windows
                assert await rpc.turn(thread) == 600000 * percent // 100
                await stop()
                rpc = await start()
                await rpc.request("thread/resume", {"threadId": sibling_id})
                assert await rpc.turn(sibling_id) == middle * percent // 100
                assert project_config.read_bytes() == project_before
                assert history.read_bytes().startswith(history_before)
                for database in home.glob("state_*.sqlite"):
                    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
                        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                result["thread_scope"] = {"custom": 485000 * percent // 100,
                    "sibling_and_fork": 600000 * percent // 100, "reset_inherits_project": True,
                    "custom_restart": True, "adaptive_windows": private_windows, "adaptive_restart": True,
                    "project_config_unchanged": True, "history_preserved": True, "database_integrity": True}
                configured_project = directory / "configured-project"
                configured_project.mkdir()
                global_config.write_text(global_config.read_text() + f'\n[projects.{json.dumps(str(configured_project))}]\ntrust_level = "trusted"\n')
                configurable_options = json.dumps({"lower_percent": 30, "upper_percent": 50, "tiers": [320000, 550000, 800000]})

                async def update_policy(mode, value=""):
                    async def invoke(*arguments):
                        command = await asyncio.create_subprocess_exec(str(PYTHON), "-B", str(RESOURCES / "context_config.py"),
                            *arguments, env=environment, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                        output, errors = await command.communicate()
                        assert command.returncode == 0, errors.decode()
                        return json.loads(output)
                    current = await invoke("status", str(configured_project))
                    return await invoke("save", str(configured_project), value, current["revision"], mode, configurable_options)

                original_adaptive = await update_policy("adaptive")
                configured = await rpc.request("thread/start", {"model": MODEL, "cwd": str(configured_project),
                    "approvalPolicy": "never", "sandbox": "read-only"})
                configured_id = configured["thread"]["id"]
                force_large_tokens = 300000
                force_large_turns = 1
                configured_windows = [await rpc.turn(configured_id) for _ in range(3)]
                assert configured_windows == [320000 * percent // 100, 320000 * percent // 100, 550000 * percent // 100], configured_windows
                await update_policy("custom", "485")
                assert await rpc.turn(configured_id) == 485000 * percent // 100
                returned_adaptive = await update_policy("adaptive")
                assert returned_adaptive["revision"] != original_adaptive["revision"]
                reset_window = await rpc.turn(configured_id)
                assert reset_window == 320000 * percent // 100, reset_window
                await stop()
                rpc = await start()
                await rpc.request("thread/resume", {"threadId": configured_id})
                assert await rpc.turn(configured_id) == reset_window
                for database in home.glob("state_*.sqlite"):
                    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
                        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                result["configurable_policy"] = {"thresholds": [30, 50], "tiers": [320000, 550000, 800000],
                    "observed_windows": configured_windows, "custom_return_initial": reset_window, "reset_survives_restart": True,
                    "database_integrity": True}
                result["passed"] = True
            except Exception as error:
                result["error"] = f"{type(error).__name__}: {error}"
            finally:
                await stop()
    await server.cleanup()
    OUTPUT.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return result["passed"]


raise SystemExit(0 if asyncio.run(run()) else 1)
