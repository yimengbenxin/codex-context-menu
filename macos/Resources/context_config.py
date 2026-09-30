import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import tomllib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent / "vendor"))
import tomlkit
from thread_settings import thread_status, save_thread
import adaptive_settings

KEYS = ("model_context_window", "model_auto_compact_token_limit")


def adaptive_status():
    backend = Path.home() / "Library/Application Support/CodexContextTool/backend"
    if not backend.exists():
        return {"adaptive": False, "reason": "只复制应用尚未完成接入。请在本工具中完成组件接入；重启不会补装组件。"}
    if backend.resolve().parent.parent != Path(__file__).resolve().parent:
        return {"adaptive": False, "reason": "已接入组件属于另一份应用安装。请为当前应用完成接入 / 重新验证。"}
    try:
        result = subprocess.run([str(backend), "--context-capability"], capture_output=True, text=True, timeout=20)
        return json.loads(result.stdout) if result.returncode == 0 else {"adaptive": False, "reason": "组件检查失败，请重新验证接入。"}
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return {"adaptive": False, "reason": "组件检查失败，请重新验证接入。"}


def adaptive_enabled(document):
    value = document.get("features", {}).get("adaptive_context_budget", False)
    return value.get("enabled", False) if isinstance(value, dict) else bool(value)


def parse_k(value):
    normalized = value.strip()
    if not normalized:
        return None
    match = re.fullmatch(r"([0-9]+)[kK]?", normalized)
    if not match:
        raise ValueError("请输入正整数，单位 K，例如 485；留空恢复默认。")
    tokens = int(match.group(1)) * 1000
    if not 0 < tokens <= 2**63 - 1:
        raise ValueError("上下文必须是有效的正整数。")
    return tokens


def read_config(path):
    if path.is_symlink():
        raise ValueError("配置文件不能是符号链接。")
    return path.read_bytes() if path.exists() else b""


def revision(raw):
    return hashlib.sha256(raw).hexdigest()


def status(root):
    root = Path(root).resolve(strict=True)
    if not root.is_dir() or root == Path.home() / ".codex":
        raise ValueError("请选择有效的项目目录，不能选择全局 Codex 配置目录。")
    directory = root / ".codex"
    if directory.is_symlink():
        raise ValueError("项目 .codex 目录不能是符号链接。")
    path = directory / "config.toml"
    raw = read_config(path)
    document = tomllib.loads(raw.decode("utf-8"))
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    if path == home.resolve() / "config.toml":
        raise ValueError("不能修改全局 Codex 配置。")
    global_config = home / "config.toml"
    global_document = tomllib.loads(read_config(global_config).decode("utf-8"))
    inherited = []
    for candidate in [global_config, *[parent / ".codex/config.toml" for parent in reversed(root.parents)]]:
        if candidate == path or not candidate.exists():
            continue
        values = tomllib.loads(read_config(candidate).decode("utf-8"))
        overrides = {key: values[key] for key in KEYS if key in values}
        if "adaptive_context_budget" in values.get("features", {}):
            overrides["adaptive_context_budget"] = int(adaptive_enabled(values))
        if overrides:
            inherited.append({"path": str(candidate), "values": overrides})
    projects = global_document.get("projects", {})
    trusted = False
    for candidate in [root, *root.parents]:
        entries = [entry for project, entry in projects.items() if Path(project).resolve() == candidate]
        if entries:
            trusted = entries[0].get("trust_level") == "trusted"
            break
    capability = adaptive_status()
    return {"root": str(root), "path": str(path), "revision": revision(raw),
            "window": document.get(KEYS[0]), "compact": document.get(KEYS[1]),
            "adaptive": adaptive_enabled(document),
            "adaptive_available": capability.get("adaptive", False),
            "adaptive_reason": capability.get("reason"), "adaptive_options": adaptive_settings.from_project(document),
            "adaptive_defaults": adaptive_settings.options(),
            "trusted": trusted, "inherited": inherited}


def save(root, value, expected_revision, mode="custom", adaptive_raw=None):
    if mode not in ("default", "custom", "adaptive"):
        raise ValueError("不支持的上下文模式。")
    tokens = parse_k(value) if mode == "custom" else None
    initial = status(root)
    if mode == "adaptive" and not initial["adaptive_available"]:
        raise ValueError("自适应运行时尚未验证，或官方软件已更新；未修改项目。")
    if not initial["trusted"]:
        raise ValueError("Codex 尚未信任此项目，请先在 Codex 中打开并信任它。")
    path = Path(initial["path"])
    if initial["revision"] != expected_revision:
        raise ValueError("配置已被其他程序修改，请点击重新读取。")
    if tokens is None and mode != "adaptive" and not path.exists():
        return initial
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.parent / "context-menu.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        raw = read_config(path)
        if revision(raw) != expected_revision:
            raise ValueError("配置已被其他程序修改，请点击重新读取。")
        document = tomlkit.parse(raw.decode("utf-8"))
        for key in KEYS:
            document.pop(key, None)
        features = document.get("features")
        if features is not None:
            features.pop("adaptive_context_budget", None)
        if mode == "adaptive":
            adaptive_settings.write_project(document, initial, adaptive_raw)
            if features is None:
                features = document["features"] = tomlkit.table()
            if features.get("token_budget") or document.get("model_auto_compact_token_limit_scope") == "body_after_prefix":
                raise ValueError("自适应与现有 token_budget / body_after_prefix 设置冲突，未修改。")
            features["adaptive_context_budget"] = True
        if tokens is not None:
            document[KEYS[0]] = tokens
        updated = tomlkit.dumps(document).encode("utf-8")
        parsed = tomllib.loads(updated.decode("utf-8"))
        if parsed.get(KEYS[0]) != tokens or KEYS[1] in parsed:
            raise ValueError("配置验证失败，未写入。")
        if updated != raw:
            backups = path.parent / "context-menu-backups"
            if backups.is_symlink():
                raise ValueError("备份目录不能是符号链接。")
            backups.mkdir(exist_ok=True)
            backup = backups / f"config-{time.time_ns()}.toml"
            backup_descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(backup_descriptor, "wb") as output:
                output.write(raw)
            mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
            temporary_descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".context-menu-")
            try:
                with os.fdopen(temporary_descriptor, "wb") as output:
                    os.fchmod(output.fileno(), mode)
                    output.write(updated)
                    output.flush()
                    os.fsync(output.fileno())
                if revision(read_config(path)) != expected_revision:
                    raise ValueError("配置发生并发修改，未覆盖。")
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return status(root)


if __name__ == "__main__":
    try:
        preview = sys.argv[-1:] == ["--preview"]
        if preview:
            sys.argv.pop()
        command, project_root = sys.argv[1:3]
        if command == "thread-status":
            result = thread_status(status(project_root), sys.argv[3], read_config, revision)
        elif command == "thread-save":
            result = save_thread(status(project_root), *sys.argv[3:7], read_config, revision, parse_k,
                adaptive_raw=sys.argv[7] if len(sys.argv) > 7 else None)
        elif command == "status":
            result = status(project_root)
        elif command == "save":
            result = save(project_root, *sys.argv[3:7])
        else:
            raise ValueError("不支持的设置命令。")
        if preview:
            from adaptive_preview import preview_status
            result.update(preview_status(result, sys.argv[3] if command.startswith("thread-") else None))
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
