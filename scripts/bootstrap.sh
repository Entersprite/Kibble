#!/usr/bin/env bash
# One-time setup check for a fresh machine. Reports what is missing; changes
# nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

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
check "swift-format" "xcrun --find swift-format"

echo "Project:"
check "Config/Local.xcconfig (OAuth client ID)" "test -f Config/Local.xcconfig"
check "GChat.xcodeproj generated" "test -d GChat.xcodeproj"
check "stable dev signing identity" \
    "security find-identity -v -p codesigning | grep -q 'GChat Dev'"

echo
echo "$ok ok, $fail missing"
[[ $fail -eq 0 ]] || cat <<'HINT'

Missing items are expected on a fresh clone:
  Local.xcconfig      cp Config/Local.xcconfig.example Config/Local.xcconfig
  GChat.xcodeproj     ./scripts/generate.sh
  dev identity        ./scripts/create-dev-cert.sh   (optional until OAuth work)
HINT
