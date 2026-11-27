#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle=${1:-'Загрузчик моделей.app'}
work=$(mktemp -d "${TMPDIR:-/tmp}/model-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
for arch in arm64 x86_64; do
    xcrun swiftc -O -target "$arch-apple-macos14.0" -module-cache-path "$work/cache" ModelDownloader.swift -o "$work/ModelDownloader-$arch"
done
xcrun lipo -create "$work/ModelDownloader-arm64" "$work/ModelDownloader-x86_64" -output "$work/ModelDownloader"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources/en.lproj" "$resources/ru.lproj"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
/usr/bin/plutil -convert binary1 -o "$resources/en.lproj/Localizable.strings" English.json
/usr/bin/python3 -c 'import json, plistlib, sys; data = json.load(open("English.json")); plistlib.dump({k:k for k in data}, open(sys.argv[1],"wb"), fmt=plistlib.FMT_BINARY)' "$resources/ru.lproj/Localizable.strings"
cp English.json model_gui_worker.py 'Скачать модели.command' 'Реестр моделей.md' "$bundle/Contents/Resources/"
mv "$work/ModelDownloader" "$bundle/Contents/MacOS/ModelDownloader"
codesign --force --sign - "$bundle"
codesign --verify --strict --all-architectures "$bundle"
