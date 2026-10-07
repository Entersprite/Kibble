#!/usr/bin/env bash
# Build the app. Pass --fast to skip code signing for a quick typecheck.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
# shellcheck source=dev-identity.sh
source "$(dirname "$0")/dev-identity.sh"

args=(
    -project Kibble.xcodeproj
    -scheme KibbleMac
    -configuration "$CONFIG"
    -destination "platform=macOS"
    -derivedDataPath DerivedData
)

developer_id=$(developer_id_identity)

if [[ "${1:-}" == "--fast" ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "$developer_id" ]]; then
    # The owner's Developer ID, for Debug too: Debug and Release share the
    # bundle identifier and so the Keychain item, and two signers would prompt
    # on every switch between them.
    #
    # Set via KIBBLE_SIGN_IDENTITY, not CODE_SIGN_IDENTITY: command-line
    # settings apply to every target, and a named identity on SwiftPM
    # dependency resource bundles makes Xcode demand a team for them.
    # project.yml maps both onto the app target alone.
    args+=(KIBBLE_SIGN_IDENTITY="$developer_id" KIBBLE_TEAM="$(team_of_identity "$developer_id")")
else
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if grep -q "$KIBBLE_DEV_IDENTITY" <<<"$identities"; then
        # No Developer ID (a fork): the stable self-signed identity, so
        # Keychain grants persist across rebuilds.
        args+=(KIBBLE_SIGN_IDENTITY="$KIBBLE_DEV_IDENTITY")
    fi
fi

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${args[@]}" build | xcbeautify
else
    xcodebuild "${args[@]}" build
fi
