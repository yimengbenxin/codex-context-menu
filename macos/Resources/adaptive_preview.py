import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tomllib
import uuid

import runtime_probe


def selected_model(home, root, thread_id):
    if thread_id:
        identifier = str(uuid.UUID(thread_id))
        uri = (home / "state_5.sqlite").resolve().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=1) as database:
            row = database.execute("SELECT model FROM threads WHERE id = ? AND cwd = ?", (identifier, str(root))).fetchone()
        if not row or not row[0]:
            raise ValueError("当前对话尚未记录模型，无法读取官方档位。")
        return row[0]
    model = None
    for candidate in [home / "config.toml", *[parent / ".codex/config.toml" for parent in reversed(root.parents)], root / ".codex/config.toml"]:
        if candidate.is_file():
            document = tomllib.loads(candidate.read_text())
            if document.get("profile") or document.get("model_catalog_json"):
                raise ValueError("当前项目使用模型配置档或自定义目录，请定位具体对话读取档位。")
            model = document.get("model", model)
    if not model:
        raise ValueError("项目未指定模型，请定位具体对话读取官方档位。")
    return model


def preview_status(status, thread_id=None):
    try:
        home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
        model = selected_model(home, Path(status["root"]), thread_id)
        catalog = json.loads((home / "models_cache.json").read_text())
        _, node = runtime_probe.verify_identity(*runtime_probe.discover())
        policy = Path(__file__).parent / "adaptive/policy.mjs"
        result = subprocess.run([str(node), str(policy), "--preview"], input=json.dumps({"catalog": catalog, "model": model}),
            capture_output=True, text=True, check=True, timeout=10)
        return {"adaptive_preview": json.loads(result.stdout)}
    except (OSError, ValueError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
        return {"adaptive_preview_reason": f"官方档位暂未读取：{error}"}
