import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
from compaction_accounting import reconstruct

FIELDS = {"id", "project", "thread", "model", "budget", "percent", "scope", "target", "before_input", "before_total",
          "after_total", "usage_age_ms", "manual", "status", "at", "duration_ms"}
COUNTS = {"target", "before_input", "before_total", "after_total", "usage_age_ms", "duration_ms"}


def database_path(home):
    directory = Path(home) / "context-menu"
    file = directory / "compaction-observations.sqlite3"
    if directory.is_symlink() or file.is_symlink():
        raise ValueError("统计路径不能是符号链接。")
    return file


def record(home, row):
    if set(row) != FIELDS or type(row["manual"]) is not bool or row["status"] not in ("completed", "failed", "incomplete"):
        raise ValueError("压缩观测格式无效。")
    for name in ("id", "project", "thread", "model", "scope"):
        if not isinstance(row[name], str) or not 0 < len(row[name]) <= 128:
            raise ValueError("压缩观测标识无效。")
    if type(row["budget"]) is not int or not 0 < row["budget"] <= 2**53 - 1:
        raise ValueError("预算无效。")
    if row["percent"] is not None and (type(row["percent"]) is not int or not 1 <= row["percent"] <= 99):
        raise ValueError("百分比无效。")
    for name in COUNTS | {"at"}:
        if row[name] is None and name in ("at", "duration_ms"):
            raise ValueError("时间无效。")
        if row[name] is not None and (type(row[name]) is not int or not 0 <= row[name] <= 2**53 - 1):
            raise ValueError("用量无效。")
    row = {**row, "accounting": reconstruct(home, [row]).get(row["id"])}
    file = database_path(home)
    file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(file, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    os.fchmod(descriptor, 0o600)
    os.close(descriptor)
    with sqlite3.connect(file, timeout=1) as connection:
        connection.execute("CREATE TABLE IF NOT EXISTS samples(id TEXT PRIMARY KEY, project TEXT, thread TEXT, model TEXT, budget INTEGER, at INTEGER, payload TEXT)")
        connection.execute("INSERT OR IGNORE INTO samples VALUES(?,?,?,?,?,?,?)", (*[row[name] for name in ("id", "project", "thread", "model", "budget", "at")], json.dumps(row)))
        connection.execute("DELETE FROM samples WHERE id IN (SELECT id FROM samples ORDER BY at DESC, id DESC LIMIT -1 OFFSET 10000)")


def summarize(rows, maximum_percent):
    groups = {}
    for row in rows:
        groups.setdefault((row["percent"], row["scope"]), []).append(row)
    result = []
    for (percent, scope), samples in groups.items():
        automatic = [row for row in samples if not row["manual"] and row["status"] == "completed"]
        measured = [row for row in automatic if row.get("accounting") is not None]
        triggered = [row for row in measured if row["target"] is not None]
        excess = sorted(max(0, row["accounting"]["upper_total"] - row["budget"]) for row in measured)
        trigger_excess = sorted(max(0, row["accounting"]["upper_total"] - row["target"]) for row in triggered)
        crossed = [value for value in excess if value > 0]
        p95 = excess[math.ceil(len(excess) * .95) - 1] if excess else None
        trigger_p95 = trigger_excess[math.ceil(len(trigger_excess) * .95) - 1] if trigger_excess else None
        recommended = None
        if percent is not None and len(triggered) >= 10 and len(triggered) >= len(automatic) * .8:
            candidate = math.floor((samples[0]["budget"] - trigger_p95) * 100 / samples[0]["budget"]) if crossed else percent
            recommended = min(percent, maximum_percent, max(1, candidate))
        result.append({"percent": percent, "scope": scope, "samples": len(samples), "automatic": len(automatic),
            "manual": sum(row["manual"] for row in samples), "failed": sum(row["status"] != "completed" for row in samples),
            "measured": len(measured), "unknown": len(automatic) - len(measured), "crossed": len(crossed),
            "observed_rate": len(crossed) / len(measured) if measured else None,
            "reported_available": sum(row["before_total"] is not None for row in automatic),
            "uncompensated_rate": sum(row["accounting"]["lower_total"] > row["budget"] for row in measured) / len(measured) if measured else None,
            "mean_excess": round(sum(crossed) / len(crossed)) if crossed else None, "p95_excess": p95,
            "trigger_crossed": sum(value > 0 for value in trigger_excess), "trigger_measured": len(triggered), "trigger_p95_excess": trigger_p95,
            "recommended_percent": recommended})
    return result


def report(home, root, thread, model, budget, maximum_percent):
    empty = {"model": model, "budget": budget, "groups": [], "recent": []}
    try:
        file = database_path(home)
        if not file.exists():
            return empty
        project = hashlib.sha256(root.encode()).hexdigest()
        query = "SELECT payload FROM samples WHERE project=? AND model=? AND budget=?"
        values = [project, model, budget]
        if thread:
            query += " AND thread=?"
            values.append(thread)
        with sqlite3.connect(file.resolve().as_uri() + "?mode=ro", uri=True, timeout=.2) as connection:
            rows = [json.loads(value[0]) for value in connection.execute(query + " ORDER BY at DESC, id DESC", values)]
        missing = [row for row in rows if row.get("accounting") is None]
        estimates = reconstruct(home, missing) if missing else {}
        rows = [{**row, "accounting": row.get("accounting") or estimates.get(row["id"])} for row in rows]
        return {**empty, "groups": summarize(rows, maximum_percent), "recent": [
            {key: row[key] for key in ("at", "percent", "before_input", "before_total", "after_total", "duration_ms", "status", "manual", "accounting")}
            for row in rows[:10]]}
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
        return {**empty, "error": "本地统计暂不可读；不会影响对话或修改设置。"}


if __name__ == "__main__":
    if sys.argv[1:2] != ["record"]:
        raise ValueError("不支持的统计命令。")
    record(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")), json.loads(sys.argv[2]))
