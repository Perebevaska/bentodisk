#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID_P12_BASE64:?Missing Developer ID Application PKCS#12 secret}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing PKCS#12 export password}"
: "${APPLE_ID:?Missing Apple Account email}"
: "${APPLE_TEAM_ID:?Missing Apple Developer Team ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Missing app-specific password for notarization}"
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple Team ID' >&2; exit 1; }

umask 077
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bentodisk-notary.XXXXXX")
keychain="$work/signing.keychain-db"
cleanup() {
    if [[ -f "$keychain" ]]; then security delete-keychain "$keychain" || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | /usr/bin/base64 -D > "$work/certificate.p12"
security import "$work/certificate.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
rm "$work/certificate.p12"
unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
unset password
identity=$(security find-identity -v -p codesigning "$keychain" |
    awk -v team="$APPLE_TEAM_ID" 'index($0, "\"Developer ID Application: ") && index($0, " (" team ")\"") {print $2}')
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo 'Expected one valid Developer ID Application identity for this team, including its private key' >&2; exit 1; }

profile=BentoDiskNotary
xcrun notarytool store-credentials "$profile" --keychain "$keychain" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
unset APPLE_APP_SPECIFIC_PASSWORD APPLE_ID

image="$work/BentoDisk-macOS.dmg"
# The staging directory stays private; installed application resources need normal file modes.
umask 022
BENTODISK_SIGN_IDENTITY="$identity" BENTODISK_SIGN_KEYCHAIN="$keychain" BENTODISK_DMG_OUTPUT="$image" \
    bash packaging/build-dmg.sh
codesign --force --timestamp --sign "$identity" --keychain "$keychain" "$image"
codesign --verify --strict "$image"

auth=(--keychain "$keychain" --keychain-profile "$profile")
result="$work/notary.json"
if ! xcrun notarytool submit "$image" "${auth[@]}" --wait --output-format json > "$result" ||
    [[ "$(plutil -extract status raw "$result" 2>/dev/null)" != Accepted ]]; then
    id=$(plutil -extract id raw "$result" 2>/dev/null || true)
    if [[ -n "$id" ]]; then
        echo "Apple notarization submission: $id" >&2
        xcrun notarytool log "$id" "${auth[@]}" || true
    fi
    echo 'Notarization did not return Accepted' >&2
    exit 1
fi
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
mkdir -p dist
mv "$image" dist/BentoDisk-macOS.dmg
