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
cmp LICENSE "$app/Contents/Resources/BentoDisk-LICENSE"
icon=$(plutil -extract CFBundleIconFile raw "$app/Contents/Info.plist")
iconutil -c iconset "$app/Contents/Resources/$icon" -o "$work/verified.iconset"
[[ -s "$work/verified.iconset/icon_16x16.png" && -s "$work/verified.iconset/icon_512x512@2x.png" ]]
codesign --verify --strict --all-architectures "$app"
python="$app/Contents/Resources/Python/bin/python3"
for binary in "$app/Contents/MacOS/ModelDownloader" "$python"; do
    architectures=$(xcrun lipo -archs "$binary")
    for arch in arm64 x86_64; do
        [[ " $architectures " == *" $arch "* ]] || { echo "Missing architecture: $arch in $binary" >&2; exit 1; }
    done
done
codesign --verify --strict --all-architectures "$python"
env -i PATH=/usr/bin:/bin "$python" -IB "$app/Contents/Resources/model_gui_worker.py" --catalog |
    /usr/bin/python3 -c 'import json, sys; rows = json.load(sys.stdin); assert isinstance(rows, list) and rows'
hdiutil detach "$mount"
mounted=false
output=${BENTODISK_DMG_OUTPUT:-dist/BentoDisk-macOS.dmg}
mkdir -p "$(dirname "$output")"
mv "$image" "$output"
