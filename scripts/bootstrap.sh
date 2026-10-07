#!/usr/bin/env bash
# One-time setup check for a fresh machine. Reports what is missing; changes
# nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=dev-identity.sh
source "$(dirname "$0")/dev-identity.sh"

ok=0
fail=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  \033[32mok\033[0m   %s\n' "$1"; ok=$((ok + 1))
    else
        printf '  \033[31mmiss\033[0m %s\n' "$1"; fail=$((fail + 1))
    fi
}

echo "Toolchain:"
check "Xcode selected (not Command Line Tools)" "xcodebuild -version"
check "xcodegen" "command -v xcodegen"
check "xcbeautify" "command -v xcbeautify"
check "swiftlint" "command -v swiftlint"
# NOT `xcrun --find swift-format`. That is Apple's tool, which this repo does
# not use and which silently reformats everything if run by mistake — see the
# comment in scripts/fmt.sh. The formatter this repo needs is nicklockwood's
# `swiftformat`, a separate binary from Homebrew.
check "swiftformat (nicklockwood, NOT xcrun swift-format)" "command -v swiftformat"
check "protoc" "command -v protoc"
check "protoc-gen-swift" "command -v protoc-gen-swift"

echo "Project:"
check "generated protobuf present" \
    "test -f Packages/GChatBridgeCore/Sources/GChatBridgeCore/Generated/googlechat.pb.swift"
check "stable dev signing identity" \
    "security find-identity -v -p codesigning | grep -q '$KIBBLE_DEV_IDENTITY'"

echo
echo "$ok ok, $fail missing"
[[ $fail -eq 0 ]] || cat <<'HINT'

Remedies:
  swiftformat       brew install swiftformat
  protoc-gen-swift  brew install swift-protobuf
  generated proto   ./scripts/generate-proto.sh
  dev identity      ./scripts/create-dev-cert.sh   (interactive; needs your login password)
HINT
