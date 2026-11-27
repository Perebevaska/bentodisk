#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle=${1:-'Загрузчик моделей.app'}
work=$(mktemp -d "${TMPDIR:-/tmp}/model-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
sdk=${SPARKLE_SDK:-"$work/sparkle"}
if [[ -z ${SPARKLE_SDK:-} ]]; then
    bash packaging/fetch-sparkle.sh "$sdk"
fi
for arch in arm64 x86_64; do
    xcrun swiftc -O -target "$arch-apple-macos14.0" -module-cache-path "$work/cache" \
        -F "$sdk" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        ModelDownloader.swift -o "$work/ModelDownloader-$arch"
done
xcrun lipo -create "$work/ModelDownloader-arm64" "$work/ModelDownloader-x86_64" -output "$work/ModelDownloader"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources/en.lproj" "$resources/ru.lproj"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
iconset="$work/BentoDisk.iconset"
mkdir "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" packaging/BentoDisk.png --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" packaging/BentoDisk.png --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/BentoDisk.icns"
if [[ -n ${BENTODISK_VERSION:-} ]]; then
    for key in CFBundleVersion CFBundleShortVersionString; do
        plutil -replace "$key" -string "$BENTODISK_VERSION" "$bundle/Contents/Info.plist"
    done
fi
mkdir -p "$bundle/Contents/Frameworks"
ditto "$sdk/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
cp "$sdk/LICENSE" "$resources/Sparkle-LICENSE"
/usr/bin/plutil -convert binary1 -o "$resources/en.lproj/Localizable.strings" English.json
/usr/bin/python3 -c 'import json, plistlib, sys; data = json.load(open("English.json")); plistlib.dump({k:k for k in data}, open(sys.argv[1],"wb"), fmt=plistlib.FMT_BINARY)' "$resources/ru.lproj/Localizable.strings"
cp English.json model_gui_worker.py 'Скачать модели.command' 'Реестр моделей.md' "$bundle/Contents/Resources/"
mv "$work/ModelDownloader" "$bundle/Contents/MacOS/ModelDownloader"
codesign --force --sign - "$bundle"
codesign --verify --strict --all-architectures "$bundle"
