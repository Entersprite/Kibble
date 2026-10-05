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

# Sparkle's helpers arrive signed ad hoc, and `xcodebuild build` re-signs only
# the framework's top level. Re-sign inside out with our identity, never
# --deep (Sparkle's "Sandboxing" documentation), then the app with its own
# entitlements kept.
sparkle=$app/Contents/Frameworks/Sparkle.framework
[[ -d "$sparkle" ]] || fail "no Sparkle.framework in the app"
for item in "$sparkle"/Versions/B/XPCServices/*.xpc "$sparkle"/Versions/B/Autoupdate \
    "$sparkle"/Versions/B/Updater.app "$sparkle"; do
    [[ -e "$item" ]] || fail "missing ${item#"$app"/}; Sparkle's layout changed"
    codesign -f -s "$GCHAT_DEV_IDENTITY" -o runtime --preserve-metadata=entitlements "$item" 2>/dev/null ||
        fail "could not sign ${item#"$app"/}"
done
codesign -f -s "$GCHAT_DEV_IDENTITY" -o runtime --preserve-metadata=entitlements "$app" 2>/dev/null ||
    fail "could not sign the app"

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
# --- updatable-bundle checks ---
# A published build that fails these can never update itself again: every
# install of it is stranded on its version.
for key in SUFeedURL SUPublicEDKey; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$value" ]] || fail "Info.plist has no $key"
done
enabled=$(/usr/libexec/PlistBuddy -c 'Print :KibbleUpdatesEnabled' "$app/Contents/Info.plist" 2>/dev/null || true)
[[ "$enabled" == YES ]] || fail "updates are off in this build"
# Every nested bundle and every loose executable beside them, found rather
# than listed, so a helper a future Sparkle adds cannot ship unsigned by us.
# codesign's output is read whole before matching (pipefail).
while IFS= read -r -d '' nested; do
    nested_signature=$(codesign -dvv "$nested" 2>&1 || true)
    grep -qx "Authority=$GCHAT_DEV_IDENTITY" <<<"$nested_signature" ||
        fail "${nested#"$app"/} is not signed by $GCHAT_DEV_IDENTITY"
done < <(find "$app/Contents/Frameworks" \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \
    -o \( -type f -perm -u+x ! -path '*/Contents/MacOS/*' ! -path '*/_CodeSignature/*' \) \) -print0)
# --- end updatable-bundle checks ---
codesign --verify --deep --strict "$app" || fail "the signature does not verify"

mkdir -p dist
zip=dist/Kibble-$version.zip
rm -f "$zip"
# ditto, not zip: it keeps the bundle's extended attributes and signature intact.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "Packaged $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
shasum -a 256 "$zip"
