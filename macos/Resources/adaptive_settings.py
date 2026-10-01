import json
import uuid
import hashlib
from pathlib import Path

DEFAULTS = json.loads((Path(__file__).parent / "adaptive/defaults.json").read_text())


def options(raw=None):
    value = json.loads(raw) if isinstance(raw, str) else raw or {}
    if not isinstance(value, dict):
        raise ValueError("自适应参数格式无效。")
    lower, upper = (value.get(key, DEFAULTS[key]) for key in ("lower_percent", "upper_percent"))
    if type(lower) not in (int, float) or type(upper) not in (int, float) or not 0 <= lower < upper <= 100:
        raise ValueError("阈值需满足 0 ≤ 两次阈值 < 一次阈值 ≤ 100。")
    tiers = value.get("tiers", [None, None, None])
    if not isinstance(tiers, list) or len(tiers) != 3:
        raise ValueError("需要初始、中间、上限三个档位。")
    provided = [tier for tier in tiers if tier is not None]
    if any(type(tier) is not int or not 0 < tier <= 2**53 - 1 for tier in provided):
        raise ValueError("档位需为有效正整数 tokens；留空使用官方参数。")
    if any(left >= right for left, right in zip(provided, provided[1:])):
        raise ValueError("自适应档位必须从小到大。")
    result = {"lower_percent": lower, "upper_percent": upper, "tiers": tiers}
    if "compaction_percent" in value:
        percent = value["compaction_percent"]
        if percent is not None and (type(percent) is not int or not 1 <= percent <= 99):
            raise ValueError("压缩百分比请输入 1–99 的整数；留空跟随官方。")
        result["compaction_percent"] = percent
    return result


def from_project(document):
    table = document.get("codex_context_tool", {})
    return options({**{key: table[key] for key in ("lower_percent", "upper_percent", "compaction_percent") if key in table},
        "tiers": [table.get(name) for name in ("initial_tokens", "middle_tokens", "maximum_tokens")]})


def overrides(raw):
    return {key: value for key, value in options(raw).items() if value != DEFAULTS.get(key)}


def budget_revision(raw, thread=False):
    if thread:
        document = json.loads(raw) if raw else {}
        if "compaction_percent" not in document.get("adaptive_options", {}):
            return hashlib.sha256(raw).hexdigest()
        document["adaptive_options"].pop("compaction_percent")
        raw = json.dumps(document).encode()
    else:
        import tomlkit
        document = tomlkit.parse(raw.decode())
        if "compaction_percent" not in document.get("codex_context_tool", {}):
            return hashlib.sha256(raw).hexdigest()
        document["codex_context_tool"].pop("compaction_percent")
        if not document["codex_context_tool"]:
            document.pop("codex_context_tool")
        raw = tomlkit.dumps(document).encode()
    return hashlib.sha256(raw).hexdigest()


def validate_compaction(initial, mode, window, raw, thread=None):
    selected = options(raw) if raw is not None else initial["adaptive_options"]
    percent = selected.get("compaction_percent")
    if percent is None:
        return
    from adaptive_preview import preview_status
    preview = preview_status(initial, thread, {"mode": mode, "window": window, "percent": percent, "options": selected})
    if "adaptive_preview" not in preview:
        raise ValueError(preview["adaptive_preview_reason"])


def write_compaction(document, raw):
    if raw is None or "compaction_percent" not in options(raw):
        return
    percent = options(raw)["compaction_percent"]
    if percent is None:
        document.get("codex_context_tool", {}).pop("compaction_percent", None)
    else:
        if "codex_context_tool" not in document:
            document["codex_context_tool"] = {}
        document["codex_context_tool"]["compaction_percent"] = percent


def write_project(document, initial, raw):
    selected = options(raw) if raw is not None else initial["adaptive_options"]
    table = document.get("codex_context_tool")
    if table is None:
        document["codex_context_tool"] = {}
        table = document["codex_context_tool"]
    for key in ("lower_percent", "upper_percent"):
        if selected[key] == DEFAULTS[key]:
            table.pop(key, None)
        else:
            table[key] = selected[key]
    for name, amount in zip(("initial_tokens", "middle_tokens", "maximum_tokens"), selected["tiers"]):
        if amount is None:
            table.pop(name, None)
        else:
            table[name] = amount
    if not initial["adaptive"] or not table.get("adaptive_activation"):
        table["adaptive_activation"] = str(uuid.uuid4())
