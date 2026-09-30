# 0.6.4 · experimental macOS release

First public snapshot of the native context companion. Released 2026-09-30.

## Shipped

- Default, custom integer-K and adaptive policies, with explicit conversation/project scope.
- Exact local deep-link resolution and first-responder Command+V / Command+A editing.
- Idle next-turn changes using the signed official CLI's native cache reconstruction.
- Local Token reporting and opt-in official quota access through pinned CodexBar CLI.
- Installer preflight, per-user installation, backups and failure rollback without private QA files.

## Compatibility and installation

Only macOS 14+ Apple Silicon, Python 3.11+, the pinned official 0.159.2 CLI/Node hashes and the documented ChatGPT.app layout are supported. Double-click Install.command from the ZIP or DMG. Initial integration requires one full Codex restart. This is ad-hoc signed, not notarized. Verify SHA-256 before approving system trust prompts.

## Verification and limits

22 Swift, 23 Node, 11 project and 3 thread configuration checks passed; installer lifecycle fixtures and signed-package preflight are additional checks. Native synthetic-response lifecycle tests preserve history prefixes and SQLite integrity. Live desktop custom-budget changes and genuine desktop tools were exercised. Cache reuse may transiently drop during a reload; zero-cost switching is not promised.

Long-history adaptive promotion is not fully accepted. Dock-first behavior and direct menu-bar mode selection/double-click activation are deferred to a later release. ZIP/DMG include the same app and installer, not user state or the official/Python runtimes.

See README for exact development test commands, privacy and uninstall restoration. File checksums are supplied in the release's v0.6.4-SHA256.txt.
