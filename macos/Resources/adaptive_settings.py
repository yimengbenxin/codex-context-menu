import json
import uuid
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
    return {"lower_percent": lower, "upper_percent": upper, "tiers": tiers}


def from_project(document):
    table = document.get("codex_context_tool", {})
    return options({**{key: table[key] for key in ("lower_percent", "upper_percent") if key in table},
        "tiers": [table.get(name) for name in ("initial_tokens", "middle_tokens", "maximum_tokens")]})


def overrides(raw):
    return {key: value for key, value in options(raw).items() if value != DEFAULTS[key]}


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
