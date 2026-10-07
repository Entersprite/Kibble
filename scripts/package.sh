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

developer_id=$(developer_id_identity)
[[ -n "$developer_id" ]] ||
    fail "no Developer ID Application identity in the Keychain; a release must be notarized"
team=$(team_of_identity "$developer_id")
profile=${KIBBLE_NOTARY_PROFILE:-kibble-notary}

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
    codesign -f -s "$developer_id" -o runtime --timestamp --preserve-metadata=entitlements "$item" 2>/dev/null ||
        fail "could not sign ${item#"$app"/}"
done
codesign -f -s "$developer_id" -o runtime --timestamp --preserve-metadata=entitlements "$app" 2>/dev/null ||
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
# A release signed any other way puts the per-update Keychain prompt back for
# everyone, and cannot be notarized.
signed_by_us() {
    grep -q "^Authority=Developer ID Application: " <<<"$1" &&
        grep -qx "TeamIdentifier=$team" <<<"$1" &&
        grep -q "^Timestamp=" <<<"$1"
}
signed_by_us "$signature" || fail "the app is not signed with the Developer ID, its team and a secure timestamp"
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
    signed_by_us "$nested_signature" ||
        fail "${nested#"$app"/} is not signed with the Developer ID, its team and a secure timestamp"
done < <(find "$app/Contents/Frameworks" \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \
    -o \( -type f -perm -u+x ! -path '*/Contents/MacOS/*' ! -path '*/_CodeSignature/*' \) \) -print0)
# --- end updatable-bundle checks ---
codesign --verify --deep --strict "$app" || fail "the signature does not verify"

mkdir -p dist
zip=dist/Kibble-$version.zip
rm -f "$zip"
# ditto, not zip: it keeps the bundle's extended attributes and signature intact.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# Apple's notary service scans this exact build. Anything but Accepted stops
# here, so release.sh commits and tags nothing. notarytool's exit status is not
# trusted either way: the JSON's status decides, and an Invalid build still
# prints its log.
echo "Notarizing $zip (this takes a few minutes)…"
submission=$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json) || true
status=$(jq -r '.status // empty' <<<"$submission" 2>/dev/null || true)
[[ -n "$status" ]] || { rm -f "$zip"; fail "notarytool could not submit $zip"; }
if [[ "$status" != Accepted ]]; then
    id=$(jq -r .id <<<"$submission")
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    rm -f "$zip"
    fail "notarization ended $status"
fi

# A zip cannot be stapled; the app inside it can, and is zipped again.
xcrun stapler staple "$app" >/dev/null || fail "could not staple the app"
xcrun stapler validate "$app" >/dev/null || fail "the stapled ticket does not validate"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

assessment=$(spctl --assess --type execute -vv "$app" 2>&1) || fail "Gatekeeper rejects the app: $assessment"
grep -qx "source=Notarized Developer ID" <<<"$assessment" ||
    fail "Gatekeeper does not see a notarized Developer ID app"

echo "Packaged $zip ($(du -h "$zip" | cut -f1 | tr -d ' ')), notarized and stapled"
shasum -a 256 "$zip"
