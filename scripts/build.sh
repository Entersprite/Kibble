#!/usr/bin/env bash
# Build the app. Pass --fast to skip code signing for a quick typecheck.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
DEV_IDENTITY="GChat Dev"

args=(
    -project GChat.xcodeproj
    -scheme GChat
    -configuration "$CONFIG"
    -destination "platform=macOS"
    -derivedDataPath DerivedData
)

if [[ "${1:-}" == "--fast" ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_IDENTITY"; then
    # Stable self-signed identity present: use it so Keychain grants persist.
    #
    # Set via GCHAT_SIGN_IDENTITY, not CODE_SIGN_IDENTITY: command-line settings
    # apply to every target, and a named identity on SwiftPM dependency resource
    # bundles makes Xcode demand a DEVELOPMENT_TEAM we do not have. project.yml
    # maps this onto the app target alone.
    args+=(GCHAT_SIGN_IDENTITY="$DEV_IDENTITY")
fi

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${args[@]}" build | xcbeautify
else
    xcodebuild "${args[@]}" build
fi
