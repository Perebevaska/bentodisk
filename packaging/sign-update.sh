#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(plutil -extract CFBundleVersion raw packaging/Info.plist)
[[ "${GITHUB_REF_NAME:-v$version}" == "v$version" ]] || { echo 'Tag must match CFBundleVersion' >&2; exit 1; }
feed=$(plutil -extract SUFeedURL raw packaging/Info.plist)
out=$(mktemp -d "${TMPDIR:-/tmp}/bentodisk-feed.XXXXXX")
trap 'rm -rf "$out"' EXIT
name="BentoDisk-$version"
cp dist/BentoDisk-macOS.dmg "$out/$name.dmg"
cp packaging/release-notes.html "$out/$name.html"
tool="$SPARKLE_SDK/bin/generate_appcast"
options=(--download-url-prefix "${feed%/*}/" --maximum-deltas 0 --embed-release-notes)
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '%s' "${BENTODISK_SPARKLE_PRIVATE_KEY:?Missing signing key}" | "$tool" --ed-key-file - "${options[@]}" "$out"
else
    "$tool" --account Perebevaska.BentoDisk "${options[@]}" "$out"
fi
/usr/bin/python3 - "$out/appcast.xml" "$version" "${feed%/*}/$name.dmg" <<'PY'
import sys
import xml.etree.ElementTree as ET
path, version, url = sys.argv[1:]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(path).find("./channel/item")
enclosure = item.find("enclosure")
assert item.findtext(sparkle + "version") == version
assert enclosure.get("url") == url and enclosure.get(sparkle + "edSignature")
PY
mkdir -p dist/channel
mv "$out/$name.dmg" "$out/appcast.xml" dist/channel/
