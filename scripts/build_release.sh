#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-0.6.8}"
[[ "$version" == 0.6.8 ]] || { echo 'Use a reviewed compatibility manifest before releasing another version' >&2; exit 1; }
cd "$root"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/codex-context-release.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
bash macos/script/package_app.sh --version "$version" --output "$temporary/package"
name="CodexContextMenu-$version-macOS-arm64"
folder="$temporary/$name"
[[ ! -L "$root/dist" ]] || { echo 'Refusing symbolic-link packaging output' >&2; exit 1; }
mkdir -p "$folder" "$root/dist"
cp -R -X "$temporary/package/CodexContextMenu.app" "$folder/"
cp -X scripts/Install.command "$folder/Install.command"
cp -X macos/script/install_local.py "$folder/install_local.py"
cp -X README.md README.zh-CN.md README.en.md LICENSE "$folder/"
chmod +x "$folder/Install.command"
ln -s /Applications "$folder/Applications"
codesign --verify --deep --strict "$folder/CodexContextMenu.app"
ditto -c -k --sequesterRsrc --keepParent "$folder" "dist/$name.zip"
hdiutil create -quiet -ov -format UDZO -volname "$name" -srcfolder "$folder" "dist/$name.dmg"
hdiutil verify "dist/$name.dmg"
