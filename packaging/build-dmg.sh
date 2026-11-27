#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/bentodisk-dmg.XXXXXX")
mount="$work/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mount" || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/image" "$mount" "$work/installed"
./Собрать\ приложение.command "$work/image/BentoDisk.app"
ln -s /Applications "$work/image/Applications"
image="$work/BentoDisk-macOS.dmg"
# APFS preserves the Unicode names sealed by codesign.
hdiutil create -fs APFS -format UDZO -volname BentoDisk -srcfolder "$work/image" "$image"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$image"
mounted=true
[[ "$(readlink "$mount/Applications")" == /Applications ]]
app="$work/installed/BentoDisk.app"
ditto "$mount/BentoDisk.app" "$app"
codesign --verify --strict --all-architectures "$app"
xcrun lipo "$app/Contents/MacOS/ModelDownloader" -verify_arch arm64 x86_64
/usr/bin/python3 -B "$app/Contents/Resources/model_gui_worker.py" --catalog |
    /usr/bin/python3 -c 'import json, sys; rows = json.load(sys.stdin); assert isinstance(rows, list) and rows'
hdiutil detach "$mount"
mounted=false
mkdir -p dist
mv "$image" dist/BentoDisk-macOS.dmg
