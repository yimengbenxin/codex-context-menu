# Codex Context Menu

A native macOS companion for choosing a Codex conversation's context budget without sending configuration instructions into chat.

[简体中文](README.md) · [Downloads](https://github.com/yimengbenxin/codex-context-menu/releases) · [Issues](https://github.com/yimengbenxin/codex-context-menu/issues)

**Unofficial community software. Not developed, endorsed or supported by OpenAI.** Version 0.6.5 is an experimental, narrowly compatible release, not a universal Codex patch.

## Why / problems solved

Long tasks need explicit context-budget control without polluting project conversations. Folder selection alone is ambiguous when several chats share a project. This companion separates the selected chat, saved settings and observed running window, and applies changes at the next idle turn instead of interrupting a response.

## Features

- Native settings window with official-default, adaptive and custom integer-K modes. Blank custom input clears the selected override.
- Identify the current or most recently selected Codex window through its app WebArea title, resolve an exact unique local display name to a thread ID, and verify session metadata. Multiple subscriptions no longer block focused identification. Duplicate names require a deep link. Native Command+V editing remains available.
- Thread-only overrides, or explicitly selected project-wide settings. Thread overrides do not affect sibling conversations or new forks.
- Adaptive thresholds (default 45/65 percent) and three ordered tiers are editable. Blank tiers follow official initial, arithmetic midpoint and maximum metadata. Returning from custom mode starts at the initial tier with a new activation revision; remaining in adaptive preserves its tier across restarts.
- Default/custom changes load at the next idle turn using the **unmodified signed official CLI**. No compression-model or reasoning-effort optimization is bundled.
- Local seven-day Token reporting and manually requested official account quota via pinned CodexBar CLI. Automatic quota refresh is off by default.

## Installation / requirements

This release supports **macOS 14+, Apple Silicon and Python 3.11+**. Official CLI 0.159.0 and 0.159.2 passed isolated lifecycle acceptance. Other versions are checked for signed identity and required protocol capabilities, not pinned to the publisher's binary hash. One verified layout is:

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
```

Discovery supports Codex.app / ChatGPT.app under system or user Applications, with the supported bundled CLI/Node pairs. Preflight checks OpenAI signing identity and native read/resume/unsubscribe/config/window-feedback contracts. It records the accepted machine's own hashes for later change detection. Unsupported contracts/layouts, Intel, Windows and Linux are rejected. OpenAI executables are not downloaded, modified or re-signed.

Use the existing Codex-managed Python runtime, or Python 3.11+ at `/opt/homebrew/bin/python3` or `/usr/local/bin/python3`. No Python libraries need installing for normal use; the TOML editor is vendored with its license.

1. Download `CodexContextMenu-0.6.5-macOS-arm64.zip` or the equivalent DMG from Releases. Verify against `v0.6.5-SHA256.txt`.
2. Drag the app to Applications and open it. Mounting a DMG is not installation.
3. Click the in-app component setup/revalidation button. Copying .app alone previously missed runtime integration; restarting cannot install it. Alternatively, keep the supplied files together and double-click Install.command for a backed-up per-user installation. No administrator password is needed.
4. Fully quit and reopen Codex **once for initial integration**. This is not a per-conversation restart. Installing an updated runtime component also requires loading that new component; ordinary budget changes do not.
5. Open the companion, identify or paste a local chat link, keep **仅此对话** for a private override, choose a mode and save. Start the next turn and check **最近运行窗口**.

The bundle is ad-hoc signed, **not Developer ID notarized**. macOS may require manual trust approval under Privacy & Security after you verify the download. The installer does not disable Gatekeeper, silently remove quarantine, or bypass system warnings.

Signature preflight checks a temporary copy without Finder decoration/resource-fork metadata; quarantine is preserved. It does not modify the downloaded bundle or persistent installation during `--check`.

Read-only preflight:

```sh
python3 install_local.py ./CodexContextMenu.app --check
```

## Usage and boundaries

Focused identification requires macOS Accessibility permission. It reads the app WebArea title and a read-only local name/ID index, not the chat body. Missing permission blocks automatic guessing; deep links need no Accessibility permission. System Accessibility permission is broad, but this implementation only reads app window titles and does not control Codex UI. Non-chat pages, duplicate names, or a window/title change during lookup are rejected rather than guessed. The settings UI shows the matched title and focus origin.

One K means 1,000 tokens. The actual window can be reduced by the official effective-window percentage and model maximum; 485K need not display as 485,000. Default never hardcodes a number or model.

Setting changes apply **between turns**, not during generation. Native resume owns idle-cache reconstruction; active, externally subscribed or unrepresentable permission states can prevent a reload. A successful save is not proof of activation: observe the running window. Reloading can temporarily reduce cache reuse; zero cache cost is not promised.

The current app is a menu-bar accessory, not a Dock-first app. A Dock-focused window lifecycle, quick mode selection in the menu bar and double-click activation are **future work**, not shipped 0.6.5 features. Real long-history adaptive promotion has not received full desktop acceptance; synthetic lifecycle tests are not a quality benchmark.

## Architecture / how it works

```mermaid
flowchart LR
  User --> UI[Native settings and menu bar]
  IPC[Local desktop IPC and session metadata] --> UI
  Focus[Accessibility: focused app window title] --> Index[Read-only local display name and thread ID]
  Index --> UI
  UI --> Config[Local configuration owner]
  Config --> State[Thread state or selected project TOML]
  State --> Policy[Adaptive lifecycle controller]
  Policy --> Native[Signed official app-server]
  Native --> Logs[Local native Token events]
  Logs --> UI
  UI --> Stats[CodexBar local reporting: network denied]
  UI -->|Manual quota or opt-in refresh| Quota[CodexBar OAuth: official OpenAI endpoints]
  Tests[Unit and isolated native checks] --> Package[Reviewed source and release packages]
  Package --> User
```

## Privacy / data and network

- No telemetry, remote control listener, credential sharing or chat upload feature is added by the context controller.
- Local session logs are read to identify conversations and display usage; chat history, SQLite, official model caches and the official application are not edited.
- Thread settings live under `$CODEX_HOME/context-menu/threads`. Project-wide settings explicitly update the selected `.codex/config.toml`, with revision checks and backups. Global TOML is not changed.
- A bounded local `runtime-events.jsonl` journal records only whitelisted lifecycle metadata, not messages, tool results or credentials.
- Startup integration changes four per-user launch environment variables and stores their prior values for restoration. It does not alter the official app bundle.
- Local cost reporting runs with networking denied. **Quota reads are different:** CodexBar uses existing authentication against official OpenAI endpoints and may perform normal OAuth refresh. There is no browser-cookie fallback. Automatic quota reads default off; turn them off in the Usage tab.
- Ordinary Codex requests retain their existing official network behavior. This package is not an offline replacement for Codex. No private runtime data or test logs are shipped.

## Verification / development

Build requires Xcode command-line tools with Swift 5.10+; development tests also use Node and Python 3.11+.

```sh
swift test --package-path macos
node --test macos/Tests/adaptive.test.mjs macos/Tests/privacy-boundary.test.mjs
python3 -B -m unittest discover -s macos/Tests -p test_context_config.py
python3 -B -m unittest discover -s macos/Tests -p test_thread_settings.py
python3 -B -m unittest discover -s macos/Tests -p test_installer.py
python3 -B -m unittest discover -s macos/Tests -p test_adaptive_settings.py
python3 -B -m unittest discover -s macos/Tests -p test_runtime_probe.py
bash scripts/build_release.sh 0.6.5
```

The 0.6.5 suite includes 80 unit checks: 33 Swift, 24 Node, 11 project, 3 thread, 3 installer, 3 adaptive-setting and 3 protocol checks. Focus tests cover exact/duplicate/renamed/archived titles, bound SQL characters, read-only lookup, changed focus fingerprints and multiple subscriptions. Native synthetic-response tests cover default/custom/adaptive, recovery, restart/fork, preserved history prefixes and SQLite integrity. Earlier live desktop checks verified 485K → 315K → 485K effective windows without restarting the official processes, plus a genuine desktop tool call. Native clipboard paste and link resolution were exercised, not replaced by direct field assignment.

To run the optional native fixture, install `requirements-test.txt` into an isolated environment and run `python3 -B macos/Tests/test_adaptive_boundary.py` with the supported official app and model metadata available. It uses synthetic responses on loopback; it is not a real-model speed or quality test.

## Release variants / uninstall

ZIP and DMG contain the **same app and installer**, with no Python/official Codex runtime bundled. GitHub source archives contain the maintained native source and dependency notices, not local acceptance logs.

Before removal, use default mode to clear selected overrides if desired, then restore startup integration:

```sh
"$HOME/Library/Application Support/CodexContextTool/backend" --restore-official
launchctl bootout "gui/$(id -u)/local.wen.CodexContextMenu"
```

Move the companion app and `~/Library/LaunchAgents/local.wen.CodexContextMenu.plist` to Trash. Keep backups until satisfied. Uninstalling does not delete chat history, project backups or previously saved overrides automatically.

## License / help

MIT, retaining the upstream [Codex Token Overlay](https://github.com/soleillevant0125/codex-token-overlay) license and attribution. CodexBar 0.69.0 and tomlkit 0.13.3 are MIT dependencies; see [third-party notices](docs/THIRD_PARTY_NOTICES.md). OpenAI software is not redistributed.

Report issues with platform/app versions and a redacted symptom description. Do not attach credentials, SQLite databases or real chat logs.
