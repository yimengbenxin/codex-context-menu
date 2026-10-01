#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/codex-context-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swift test --package-path "$root/macos" --scratch-path "$scratch"
