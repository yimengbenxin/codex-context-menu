import json
from datetime import datetime
from pathlib import Path
import sqlite3


def tokens(byte_count):
    return (byte_count + 3) // 4


def reasoning_cost(item):
    content = item.get("encrypted_content")
    return tokens(max(0, len(content) * 3 // 4 - 650)) if isinstance(content, str) else 0


def local_cost(item):
    kind = item.get("type")
    if kind in ("configuration_update", "compaction_trigger"):
        return 0
    if kind in ("custom_tool_call_output", "function_call_output"):
        content = item.get("output", [])
        if isinstance(content, str):
            size = len(content.encode())
        else:
            size = 0
            for part in content:
                if part.get("type") == "input_text":
                    size += len(part.get("text", "").encode())
                elif part.get("type") == "encrypted_content":
                    size += (len(part["encrypted_content"]) * 9 + 15) // 16
                else:
                    return None
        size += sum(len((item.get(key) or "").encode()) for key in ("call_id", "name", "namespace"))
        return tokens(size)
    if kind == "message":
        content = item.get("content", [])
        if all(part.get("type") in ("input_text", "output_text") for part in content):
            return tokens(sum(len(part.get("text", "").encode()) for part in content))
    return None


class Replay:
    def __init__(self):
        self.reasoning = 0
        self.past = 0
        self.pending = 0
        self.valid = False

    def item(self, item):
        kind = item.get("type")
        if kind == "agent_message":
            self.valid = False
        if kind == "message" and item.get("role") == "user":
            texts = [part.get("text", "").lstrip() for part in item.get("content", [])]
            metadata = item.get("internal_chat_message_metadata_passthrough") or {}
            kinds = metadata.get("content_item_kinds") or []
            contextual = any(text.startswith(("# AGENTS.md instructions", "<environment_context>", "<turn_aborted>", "<subagent_notification>", "<hook_prompt>")) for text in texts)
            contextual = contextual or (bool(kinds) and len(kinds) == len(texts) and all(isinstance(value, str) and not value.startswith("user.") for value in kinds))
            if not contextual:
                self.past = self.reasoning
        if kind == "reasoning":
            self.reasoning += reasoning_cost(item)
        generated = kind in ("reasoning", "function_call", "custom_tool_call", "web_search_call", "tool_search_call", "local_shell_call", "compaction", "context_compaction", "image_generation_call")
        if generated or (kind == "message" and item.get("role") == "assistant"):
            self.pending = 0
        elif self.pending is not None:
            cost = local_cost(item)
            self.pending = self.pending + cost if cost is not None else None

    def estimate(self, row):
        reported = row.get("before_total")
        if not self.valid or self.pending is None or reported is None:
            return None
        lower = reported + self.pending
        return {"basis": "conditional_history_replay_v1", "pending_local": self.pending,
                "history_reasoning": self.past, "lower_total": lower, "upper_total": lower + self.past}


def reconstruct(home, rows):
    result = {}
    threads = {}
    for row in rows:
        threads.setdefault(row["thread"], []).append(row)
    try:
        state = Path(home) / "state_5.sqlite"
        with sqlite3.connect(state.resolve().as_uri() + "?mode=ro", uri=True, timeout=.2) as connection:
            for thread, samples in threads.items():
                entry = connection.execute("SELECT rollout_path FROM threads WHERE id=?", (thread,)).fetchone()
                if not entry:
                    continue
                rollout = Path(entry[0]).resolve()
                if not rollout.is_relative_to((Path(home) / "sessions").resolve()):
                    continue
                pending = iter(sorted(samples, key=lambda row: row["at"]))
                sample = next(pending, None)
                replay = Replay()
                with rollout.open() as stream:
                    for line in stream:
                        event = json.loads(line)
                        at = int(datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp() * 1000)
                        while sample and sample["at"] < at:
                            result[sample["id"]] = replay.estimate(sample)
                            sample = next(pending, None)
                        if not sample:
                            break
                        kind, payload = event.get("type"), event.get("payload", {})
                        if kind == "session_meta":
                            replay.valid = True
                        elif kind == "compacted":
                            replay = Replay()
                            history = payload.get("replacement_history")
                            replay.valid = isinstance(history, list)
                            for item in history or []:
                                replay.item(item)
                        elif payload.get("type") == "thread_rolled_back":
                            replay.valid = False
                        elif kind == "response_item":
                            replay.item(payload)
                    while sample:
                        result[sample["id"]] = replay.estimate(sample)
                        sample = next(pending, None)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
        return result
    return result
