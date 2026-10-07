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
    # A missing directory is a FAILURE, not a pass - the same rule this file
    # already states for lint-testsupport.py below: a check that cannot run has
    # not passed. Every caller addresses a literal path that exists today, so a
    # "no sources yet" pass can now only mean a rename or a restructure has
    # silently switched the check off. That matters most for the containment
    # scans: in an Xcode build every module lands in one products directory, so
    # `import LocalBridgeBackend` inside AppCore compiles with no declared
    # dependency at all, and this scan is the only thing enforcing it.
    if [ ! -d "$dir" ]; then
        note "$desc"
        printf '         (no such directory: %s - the scan could not run)\n' "$dir" >&2
        return 0
    fi
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

echo "Core containment (a future iOS binary must carry no protocol code):"
# LocalBridgeBackend is the ONLY package allowed to import GChatBridgeCore, and
# the app is not allowed to import it at all. That is the architecture's whole
# distribution argument: RemoteBackend and an iOS binary link the seam and the
# store, and contain nothing reverse-engineered. It erodes the moment one file
# reaches for SessionCookies directly, so it is checked rather than remembered.
# The regex tolerates an attribute prefix (@preconcurrency, @testable,
# @_implementationOnly, ...) and Swift's scoped-import form
# (`import class Module.Symbol`, where the kind word sits between `import`
# and the module) - a bare `^import` anchor lets both spellings through.
importers=$(grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([A-Za-z]+[[:space:]]+)?(GChatBridgeCore|URLSessionTransport)\b' \
              Apps Packages --include='*.swift' 2>/dev/null \
            | grep -v '^Packages/GChatBridgeCore/' \
            | grep -v '^Packages/LocalBridgeBackend/' || true)
if [ -n "$importers" ]; then
    note "GChatBridgeCore is imported outside LocalBridgeBackend"
    printf '%s\n' "$importers" | sed 's/^/         /' >&2
else
    pass "only LocalBridgeBackend imports the reverse-engineered core"
fi

echo "App layering (AppCore is what iOS links; MacHost is what it does not):"
APPCORE=Packages/AppCore/Sources/AppCore
# The design's load-bearing principle - the apps depend on ChatBackend, not on
# any connection - checked above the seam for the first time. AppCore naming a
# backend gives two futures, both bad: iOS links it and ships the protocol
# core, or iOS does not and reimplements the launch machine. See the design doc
# §3.1; this scan is what would have caught its first draft. The regex
# tolerates an attribute prefix (@preconcurrency being the one a Swift 6
# developer plausibly types to silence a Sendable warning, not a contrivance)
# and the scoped-import form (`import class Module.Symbol`) - see Core
# containment above, which has the identical shape for the identical reason.
# UserNotifications and AppKit joined the list with notification rules: the
# notification center is reached only through `NotificationDelivering`, whose
# one real conformance lives in MacHost - `UNUserNotificationCenter.current()`
# crashes under a test runner, and a future iOS host supplies its own - and
# AppKit does not exist on the iOS this package is linked by. Cocoa is the
# umbrella that re-exports AppKit, so banning AppKit alone let `import Cocoa`
# through - and on macOS `import SwiftUI` brings AppKit in too (a file with
# only that import typechecks a use of `NSWindow`). SwiftUI is banned for its
# own reason as well: views live in DesignSystem, and AppCore's stated
# dependencies are ChatKit, SyncEngine and DesignSystem only.
scan "$APPCORE" \
  '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([A-Za-z]+[[:space:]]+)?(LocalBridgeBackend|RemoteBackend|FixtureBackend|GChatBridgeCore|WebKit|Security|UserNotifications|AppKit|Cocoa|SwiftUI)\b' \
  "AppCore imports no backend, no credential store, no web view, no notification center, no AppKit and no SwiftUI"

# The app target is a shell. This was the one structure rule in CLAUDE.md with
# no scan behind it, and it is the one that drifted: AppEnvironment.swift grew
# to 363 lines of launch machine while its own header said there was no logic
# in it. Stated as an import ban rather than a list of forbidden symbols,
# because a symbol list only forbids the three things someone already thought
# of.
scan "Apps" \
  '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([A-Za-z]+[[:space:]]+)?(GRDB|SyncEngine|LocalBridgeBackend|FixtureBackend)\b' \
  "the app target imports no store and no backend"

# Sparkle is reached through AppUpdating, and SparkleUpdater.swift is its one
# importer: everything above it is tested against a fake, and a future iOS app
# never links an updater.
importers=$(grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([A-Za-z]+[[:space:]]+)?Sparkle\b' \
              --include='*.swift' Apps Packages 2>/dev/null \
            | grep -v '/\.build/' | grep -vx 'Packages/MacHost/Sources/MacHost/SparkleUpdater.swift' || true)
if [ -n "$importers" ]; then
    note "Sparkle is imported outside SparkleUpdater.swift"
    printf '%s\n' "$importers" | sed 's/^/         /' >&2
else
    pass "only SparkleUpdater.swift imports Sparkle"
fi

# Every entry into .needsSignIn must erase the store first, and the way that is
# structural rather than a convention is that exactly one function constructs
# the phase. Session 15 §2 found four routes where the brief assumed one; three
# of them did not erase. Without this scan a fifth reintroduces the bug.
#
# Matches the bare word, not ".needsSignIn(" - a first-class reference to the
# case (`let ctor = LaunchPhase.needsSignIn`) never writes ".needsSignIn(" as a
# contiguous substring, so anchoring on the call form alone would miss it. Two
# kinds of line legitimately say the word without constructing anything: a
# comment, and any line where `case` introduces the word as a *pattern* rather
# than a construction. "Pattern" is not "the line starts with case" in either
# direction: a switch arm can construct the phase on the same line as an
# unrelated pattern (`case .somethingElse: return LaunchPhase.needsSignIn(...)`),
# so starting with `case` does not make a line safe; and the idiomatic
# single-check read forms, `if case .needsSignIn = phase` /
# `guard case .needsSignIn = phase else { ... }`, do not start with `case` at
# all, so requiring that would flag a correct read as a violation - worse than
# missing a construction, because a scan that cries wolf on ordinary code is a
# scan someone deletes (see `lint-testsupport.py`'s header).
#
# What actually distinguishes a pattern mention from a construction is what
# comes between `case` and the word: nothing that could only appear in a
# value expression. A switch arm's pattern list ends at `:`; an `if`/`guard
# case` binding ends at `=`. So `case` followed by anything except `:` or `=`
# up to the word is a pattern mention regardless of where `case` sits in the
# line (a bare arm, an `if case`, a `guard case`, or a compound condition
# after a comma) - and a real construction can never satisfy that, because
# reaching a construction's own `LaunchPhase.needsSignIn(` from a `case`
# earlier in the line always crosses that `case`'s terminating `:` or `=` first.
needs=""
while IFS= read -r -d '' f; do
    case "$f" in
        */LaunchPhase.swift | */AppEnvironment.swift) continue ;;
    esac
    hit=$(grep -nE 'needsSignIn' "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*//|(^|[^A-Za-z])case[[:space:]]+[^:=]*\bneedsSignIn\b' || true)
    [ -n "$hit" ] && needs="${needs}${f}
"
done < <(swift_files "$APPCORE")
if [ -n "$needs" ]; then
    note "the .needsSignIn phase is constructed outside enterNeedsSignIn"
    printf '%s' "$needs" | sed 's/^/         /' >&2
else
    pass ".needsSignIn is constructed in exactly one place"
fi

echo "Reducer purity (the bridge server runs this file verbatim):"
# The architecture's condition for read state and history not drifting into two
# sources of truth is that the server reduces events with THIS reducer rather
# than one written to match it. The moment the reducer knows about GRDB, the
# server needs its own copy. Only the Store/ half may import a database.
REDUCER=Packages/SyncEngine/Sources/SyncEngine/Reducer
scan "$REDUCER" '^[[:space:]]*import[[:space:]]+(GRDB|SQLite3)\b' \
  "the sync reducer imports no database"

echo "Fixture determinism (FixtureBackend must not read a clock or wait):"
# Everything above the seam is tested against FakeBackend, so a wall clock or a
# random identifier in there makes those tests non-reproducible - and the
# failure surfaces in the code under test, not in the fixture. The package's own
# determinism test catches Date(); it cannot catch Task.sleep, which shows up as
# a slow suite rather than a wrong one. Hence this scan.
FIXTURE=Packages/FixtureBackend/Sources/FixtureBackend
if [ -d "$FIXTURE" ]; then
    # FixtureDemoDriver is the one file allowed to wait: it plays a script at
    # human speed for the app's Debug backend. Nothing else may.
    hits=$(swift_files "$FIXTURE" | xargs -0 grep -nE \
             '\bDate\(\)|\bDate\.now\b|\bUUID\(|Task\.sleep|\.random' 2>/dev/null \
           | grep -v '/FixtureDemoDriver\.swift:' || true)
    if [ -n "$hits" ]; then
        note "a clock, randomness or sleeping outside FixtureDemoDriver"
        printf '%s\n' "$hits" | sed 's/^/         /' >&2
    else
        pass "no clock, randomness or waiting outside FixtureDemoDriver"
    fi
else
    pass "no clock or waiting outside FixtureDemoDriver (no sources yet)"
fi

echo "Test-support containment:"
# See scripts/lint-testsupport.py for the rule and why it reads the package
# graph rather than the manifest source. Exit 2 (unusable input) is treated as
# a FAILURE, not a pass: a check that cannot run has not passed.
support_ok=1
for m in Packages/*/Package.swift; do
    [ -f "$m" ] || continue
    pkg=$(dirname "$m")
    out=$( cd "$pkg" && swift package dump-package 2>/dev/null \
           | python3 ../../scripts/lint-testsupport.py "$(basename "$pkg")" )
    rc=$?
    if [ "$rc" != 0 ]; then
        support_ok=0
        note "test-support scaffolding reachable from shipping code ($(basename "$pkg"))"
        [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/         /' >&2
        [ "$rc" = 2 ] && printf '         (check could not run - treated as failure)\n' >&2
    fi
done
[ "$support_ok" = 1 ] && pass "TestSupport targets are neither products nor non-test dependencies"

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
    # Build tests before running them. On a cold build in a package with a
    # build-tool plugin, `swift test` alone can report "no tests found" for
    # test targets that exist and compile perfectly well. Doing the build as
    # its own step is cheap when incremental and removes that flake.
    ( cd "$pkg" && swift build --build-tests >/dev/null 2>&1 ) || true
    ( cd "$pkg" && swift test "$@" ) || fail=1
done
[ "$ran" = 1 ] || echo "  (no SwiftPM packages yet)"

echo "Third-party notices (every linked dependency's license ships with the app):"
# Sparkle, GRDB and swift-protobuf are linked into the app, and their licenses
# require their notices in every copy. scripts/check-notices.sh holds
# THIRD_PARTY_NOTICES.txt to every pin at its version. After the unit suites,
# because `swift test` is what refreshes a lockfile after a manifest change.
notices_out=$(./scripts/check-notices.sh Packages/*/Package.resolved 2>&1)
case $? in
    0) pass "THIRD_PARTY_NOTICES.txt names all $notices_out resolved dependencies at their versions" ;;
    1) note "THIRD_PARTY_NOTICES.txt has no heading for every resolved dependency at its version"
       printf '%s\n' "$notices_out" | sed 's/^/         missing: /' >&2 ;;
    *) note "the third-party notices check could not run"
       printf '%s\n' "$notices_out" | sed 's/^/         /' >&2 ;;
esac
echo
if [ "$fail" = 0 ]; then echo "all checks passed"; else echo "FAILURES ABOVE" >&2; fi
exit "$fail"
