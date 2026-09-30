import json
import uuid


def options(raw=None):
    value = json.loads(raw) if isinstance(raw, str) else raw or {}
    if not isinstance(value, dict):
        raise ValueError("自适应参数格式无效。")
    lower, upper = value.get("lower_percent", 45), value.get("upper_percent", 65)
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
    return options({"lower_percent": table.get("lower_percent", 45), "upper_percent": table.get("upper_percent", 65),
        "tiers": [table.get(name) for name in ("initial_tokens", "middle_tokens", "maximum_tokens")]})


def write_project(document, initial, raw):
    selected = options(raw) if raw is not None else initial["adaptive_options"]
    table = document.get("codex_context_tool")
    if table is None:
        document["codex_context_tool"] = {}
        table = document["codex_context_tool"]
    table["lower_percent"], table["upper_percent"] = selected["lower_percent"], selected["upper_percent"]
    for name, amount in zip(("initial_tokens", "middle_tokens", "maximum_tokens"), selected["tiers"]):
        if amount is None:
            table.pop(name, None)
        else:
            table[name] = amount
    if not initial["adaptive"] or not table.get("adaptive_activation"):
        table["adaptive_activation"] = str(uuid.uuid4())
