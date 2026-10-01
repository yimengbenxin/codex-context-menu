import fcntl
import json
import os
from pathlib import Path
import tempfile
import uuid
import adaptive_settings


def settings_path(thread_id):
    identifier = str(uuid.UUID(thread_id))
    if identifier != thread_id.lower():
        raise ValueError("无效的对话 ID。")
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    directory = home / "context-menu" / "threads"
    for parent in [home, directory.parent, directory]:
        if parent.is_symlink():
            raise ValueError("对话设置目录不能是符号链接。")
    return directory / f"{identifier}.json"


def thread_status(project, thread_id, read_config, revision):
    path = settings_path(thread_id)
    raw = read_config(path)
    entry = json.loads(raw) if raw else None
    if entry is not None:
        if entry.get("root") != project["root"] or entry.get("thread") != thread_id.lower():
            raise ValueError("对话设置与项目不一致，未加载。")
        if entry.get("mode") not in ("default", "custom", "adaptive"):
            raise ValueError("对话设置格式无效。")
        window = entry.get("window")
        if entry["mode"] == "custom" and (type(window) is not int or not 0 < window <= 2**63 - 1):
            raise ValueError("对话上下文数值无效。")
    inherited = list(project["inherited"])
    values = {key: project[name] for key, name in [("model_context_window", "window"),
              ("model_auto_compact_token_limit", "compact")] if project[name] is not None}
    if project["adaptive"]:
        values["adaptive_context_budget"] = 1
    if values:
        inherited.append({"path": project["path"], "values": values})
    return {**project, "path": str(path), "revision": revision(raw), "scope": "thread",
            "thread": thread_id.lower(), "override": entry is not None and entry["mode"] != "default",
            "budget_revision": adaptive_settings.budget_revision(raw, thread=True), "project_budget_revision": project["budget_revision"],
            "compaction_percent": entry.get("adaptive_options", {}).get("compaction_percent", project.get("compaction_percent")) if entry else project.get("compaction_percent"),
            "effective_adaptive": project["adaptive"], "project_revision": project["revision"],
            "window": entry.get("window") if entry else None,
            "adaptive_options": adaptive_settings.options(entry.get("adaptive_options", project.get("adaptive_options"))) if entry else project.get("adaptive_options", adaptive_settings.options()),
            "adaptive_activation": entry.get("adaptive_activation") if entry else None,
            "compact": None, "adaptive": entry is not None and entry["mode"] == "adaptive",
            "inherited": inherited}


def save_thread(project, thread_id, value, expected, mode, read_config, revision, parse_k, adaptive_raw=None):
    if mode not in ("default", "custom", "adaptive"):
        raise ValueError("不支持的上下文模式。")
    if not project["trusted"]:
        raise ValueError("Codex 尚未信任此项目，未保存。")
    if mode == "adaptive" and not project["adaptive_available"]:
        raise ValueError("自适应运行时不可用，未保存。")
    tokens = parse_k(value) if mode == "custom" else None
    current = thread_status(project, thread_id, read_config, revision)
    adaptive_settings.validate_compaction(current, mode, tokens, adaptive_raw, thread_id)
    selected = adaptive_settings.overrides(adaptive_raw if adaptive_raw is not None else current["adaptive_options"])
    path = Path(current["path"])
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path.with_suffix(".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if revision(read_config(path)) != expected:
            raise ValueError("设置已被其他程序修改，请点击重新读取。")
        if (mode == "default" or (mode == "custom" and tokens is None)) and selected.get("compaction_percent") is None:
            if path.exists():
                path.unlink()
        else:
            entry = {"root": project["root"], "thread": thread_id.lower(), "mode": "default" if mode == "custom" and tokens is None else mode, "window": tokens,
                "adaptive_options": selected,
                "adaptive_activation": current["adaptive_activation"] if mode != "adaptive" or current["adaptive"] else str(uuid.uuid4())}
            temporary_descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".settings-")
            try:
                with os.fdopen(temporary_descriptor, "w") as output:
                    os.fchmod(output.fileno(), 0o600)
                    json.dump(entry, output)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return thread_status(project, thread_id, read_config, revision)
