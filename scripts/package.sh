#!/usr/bin/env bash
# Build the Release app and zip it into dist/Kibble-<version>.zip, the file a
# GitHub Release carries. The version is whatever Config/Base.xcconfig says;
# scripts/release.sh writes it before calling this.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=dev-identity.sh
source "$(dirname "$0")/dev-identity.sh"

fail() {
    echo "package: $1" >&2
    exit 1
}

version=$(sed -nE 's/^MARKETING_VERSION = (.+)$/\1/p' Config/Base.xcconfig)
[[ -n "$version" ]] || fail "no MARKETING_VERSION in Config/Base.xcconfig"

./scripts/generate.sh >/dev/null
CONFIG=Release ./scripts/build.sh

app=DerivedData/Build/Products/Release/Kibble.app
[[ -d "$app" ]] || fail "the build produced no $app"

# Everything a downloaded copy depends on, checked on the bundle itself rather
# than trusted from the build settings.
for key in CFBundleShortVersionString CFBundleVersion; do
    built=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
    [[ "$built" == "$version" ]] || fail "$key is $built, expected $version"
done
# Read codesign's output whole before matching: `codesign | grep -q` under
# pipefail fails when grep exits on its first match and codesign then writes to
# a closed pipe, which turns a match into a miss.
signature=$(codesign -dvv "$app" 2>&1)
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
# build.sh falls back to ad-hoc signing when the identity is missing. A
# release must not: every build would then be a new signer, and macOS would
# ask for the Keychain password again after each update.
grep -qx "Authority=$GCHAT_DEV_IDENTITY" <<<"$signature" ||
    fail "not signed by $GCHAT_DEV_IDENTITY; run scripts/create-dev-cert.sh"
# get-task-allow lets any process attach a debugger. Xcode adds it unless the
# build turns that off, which project.yml does for Release.
if grep -q get-task-allow <<<"$entitlements"; then
    fail "the app carries get-task-allow"
fi
codesign --verify --deep --strict "$app" || fail "the signature does not verify"

mkdir -p dist
zip=dist/Kibble-$version.zip
rm -f "$zip"
# ditto, not zip: it keeps the bundle's extended attributes and signature intact.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "Packaged $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
shasum -a 256 "$zip"
