import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

TEAM = "2DC432GLL2"
CONTRACT = {
    "ThreadReadParams": {"threadId", "includeTurns"},
    "ConfigReadParams": {"cwd", "includeLayers"},
    "ThreadResumeParams": {"threadId", "config", "model", "sandbox", "approvalPolicy"},
    "ThreadResumeResponse": {"model", "cwd", "sandbox", "approvalPolicy", "reasoningEffort"},
    "ThreadUnsubscribeParams": {"threadId"},
    "TurnStartParams": {"threadId", "input"},
    "ThreadTokenUsageUpdatedNotification": {"threadId", "tokenUsage"},
}


def run(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=True, timeout=30)


def validate_schema(directory):
    for name, fields in CONTRACT.items():
        file = directory / "v2" / f"{name}.json"
        if not file.is_file() or not fields.issubset(json.loads(file.read_text()).get("properties", {})):
            raise RuntimeError(f"官方接口缺少 {name} 所需字段，暂不能热加载；未修改安装。")
    request = json.loads((directory / "ClientRequest.json").read_text())
    methods = json.dumps(request)
    for method in ("config/read", "thread/read", "thread/resume", "thread/unsubscribe", "turn/start"):
        if json.dumps(method) not in methods:
            raise RuntimeError(f"官方接口不支持 {method}，暂不能接入。")
    usage = (directory / "v2/ThreadTokenUsageUpdatedNotification.json").read_text()
    if '"modelContextWindow"' not in usage:
        raise RuntimeError("官方接口缺少窗口反馈，暂不能确认生效。")


def verify_identity(binary, node):
    binary, node = Path(binary).resolve(strict=True), Path(node).resolve(strict=True)
    for executable in (binary, node):
        run("/usr/bin/codesign", "--verify", "--strict", str(executable))
        identity = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(executable)],
            capture_output=True, text=True, check=True, timeout=10).stderr
        if f"TeamIdentifier={TEAM}" not in identity.splitlines():
            raise RuntimeError("只允许使用带 OpenAI 身份签名的官方程序；未重新签名或绕过校验。")
    return binary, node


def probe(binary, node):
    binary, node = verify_identity(binary, node)
    with tempfile.TemporaryDirectory(prefix="codex-context-contract-") as temporary:
        directory = Path(temporary)
        run(str(binary), "app-server", "generate-json-schema", "--experimental", "--out", str(directory))
        validate_schema(directory)
    return {"binary": str(binary), "node": str(node), "version": run(str(binary), "--version").stdout.strip(),
        "officialSha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "nodeSha256": hashlib.sha256(node.read_bytes()).hexdigest(), "contract": "round-boundary-v1"}


def discover():
    specified = os.environ.get("CODEX_CONTEXT_OFFICIAL_APP")
    apps = [Path(specified)] if specified else [base / name for base in (Path("/Applications"), Path.home() / "Applications")
        for name in ("Codex.app", "ChatGPT.app")]
    pairs = []
    for app in apps:
        resources = app / "Contents/Resources"
        for binary in (resources / "codex-cli/CodexCLI.app/Contents/MacOS/codex", resources / "codex"):
            node = resources / "cua_node/bin/node"
            if binary.is_file() and node.is_file():
                pairs.append((binary, node))
    if not pairs:
        raise RuntimeError("未找到官方 Codex / ChatGPT 应用内的 CLI 与签名 Node。请先安装官方桌面应用。")
    processes = run("/bin/ps", "-axo", "command=").stdout
    running = [pair for pair in pairs if str(pair[0]).split("/Contents/Resources/")[0] + "/Contents/MacOS/" in processes]
    candidates = running or pairs
    if len(candidates) != 1:
        raise RuntimeError("发现多个官方安装，无法唯一确定。请只运行目标安装，或通过 CODEX_CONTEXT_OFFICIAL_APP 指定。")
    return candidates[0]


def locate():
    return probe(*discover())


if __name__ == "__main__":
    if sys.argv[1:] == ["--paths"]:
        binary, node = verify_identity(*discover())
        print(json.dumps({"binary": str(binary), "node": str(node), "python": sys.executable}))
    else:
        print(json.dumps(locate()))
