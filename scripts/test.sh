#!/usr/bin/env bash
# Lints + unit suite. Needs no Xcode project, no simulator, no Google account.
#
# Deliberately NOT `set -e`: every check runs so one invocation reports every
# problem, not just the first.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
note() { printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2; fail=1; }

CORE=Packages/GChatBridgeCore/Sources/GChatBridgeCore
SEAM=Packages/ChatKit/Sources/ChatKit

# Generated protobuf is machine-produced and enormous; exclude it from source scans.
swift_files() { find "$1" -name '*.swift' -not -path '*/Generated/*' -print0 2>/dev/null; }

scan() { # dir, regex, description
    local dir="$1" re="$2" desc="$3" hits
    [ -d "$dir" ] || { pass "$desc (no sources yet)"; return 0; }
    hits=$(swift_files "$dir" | xargs -0 grep -nE "$re" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        note "$desc"; printf '%s\n' "$hits" | sed 's/^/         /' >&2
    else
        pass "$desc"
    fi
}

echo "Portability (GChatBridgeCore must compile on Linux):"
# The loud class: a platform framework import.
scan "$CORE" \
  '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*import[[:space:]]+(AppKit|UIKit|SwiftUI|WebKit|Security|CryptoKit|CoreFoundation|FoundationNetworking|Combine|OSLog|Darwin|Network)\b' \
  "no platform framework imports"
# The quiet class: types that come from Foundation on Darwin but from
# FoundationNetworking on Linux. An import ban alone would never catch these,
# and the long-poll transport is exactly where they would appear.
scan "$CORE" \
  '\b(URLSession|URLRequest|URLProtocol|HTTPURLResponse|HTTPCookieStorage|HTTPCookie|URLCredential|NSLock|os_log)\b' \
  "no Darwin-only networking/locking types"

echo "Seam purity (ChatKit is the domain; it depends on nothing):"
if [ -d "$SEAM" ]; then
    hits=$(swift_files "$SEAM" | xargs -0 grep -nE '^[[:space:]]*import[[:space:]]+' 2>/dev/null \
           | grep -vE 'import[[:space:]]+Foundation[[:space:]]*$' || true)
    if [ -n "$hits" ]; then
        note "ChatKit imports something other than Foundation"
        printf '%s\n' "$hits" | sed 's/^/         /' >&2
    else
        pass "ChatKit imports only Foundation"
    fi
else
    pass "ChatKit imports only Foundation (no sources yet)"
fi

echo "Test-support containment:"
leak=$(for m in Packages/*/Package.swift; do
    [ -f "$m" ] || continue
    awk -v M="$m" '
        /\.testTarget\(/ { intest=1 }
        /\.target\(/     { intest=0 }
        /TestSupport/    { if (!intest) print M ":" NR ": " $0 }
    ' "$m"
done)
if [ -n "$leak" ]; then
    note "a non-test target depends on a TestSupport target"
    printf '%s\n' "$leak" | sed 's/^/         /' >&2
else
    pass "TestSupport targets are referenced only by test targets"
fi

echo "Generated protobuf freshness:"
PROTO=Packages/GChatBridgeCore/Protos/googlechat.proto
HASH=Packages/GChatBridgeCore/Protos/.protohash
GEN=Packages/GChatBridgeCore/Sources/GChatBridgeCore/Generated
if [ ! -d "$GEN" ]; then
    pass "not generated yet"
elif [ ! -f "$HASH" ]; then
    note "Generated/ exists but .protohash does not — run ./scripts/generate-proto.sh"
elif [ "$(shasum -a 256 "$PROTO" | awk '{print $1}')" != "$(cat "$HASH")" ]; then
    note "googlechat.proto changed since generation — run ./scripts/generate-proto.sh"
else
    pass "generated Swift matches googlechat.proto"
fi

echo "Unit suites:"
ran=0
for m in Packages/*/Package.swift; do
    [ -f "$m" ] || continue
    pkg=$(dirname "$m"); ran=1
    echo "  --- $(basename "$pkg") ---"
    ( cd "$pkg" && swift test "$@" ) || fail=1
done
[ "$ran" = 1 ] || echo "  (no SwiftPM packages yet)"

echo
if [ "$fail" = 0 ]; then echo "all checks passed"; else echo "FAILURES ABOVE" >&2; fi
exit "$fail"
