#!/bin/zsh
set -eu
root="${0:A:h}"
for python in "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [[ -x "$python" ]]; then
    "$python" -c 'import sys; assert sys.version_info >= (3,11), "Python 3.11+ is required"'
    exec "$python" -B "$root/install_local.py" "$root/CodexContextMenu.app"
  fi
done
echo 'Python 3.11+ was not found. See README.zh-CN.md / README.md for requirements.' >&2
exit 1
