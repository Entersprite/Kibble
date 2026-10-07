#!/usr/bin/env bash
# Check that every dependency pinned in the given Package.resolved files has a
# heading line "identity version" in THIRD_PARTY_NOTICES.txt (whole line, any
# case). Licenses can change between versions, so a bumped dependency fails
# until its notice is rechecked and its heading updated.
#
# Prints how many pins it checked and exits 0; prints each missing pin and
# exits 1; exits 2 when nothing could be read, because a check that read no
# pins has not passed.
#
# test.sh runs it on the packages' lockfiles. package.sh runs it on the Xcode
# project's, which is what the shipped app was resolved from: SwiftPM ignores
# a nested package's lockfile, and the requirements are open ranges.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: check-notices.sh Package.resolved..." >&2; exit 2; }
notices="$(dirname "$0")/../THIRD_PARTY_NOTICES.txt"

pins=$(python3 - "$@" <<'PY'
import json, sys
seen = set()
for path in sys.argv[1:]:
    for pin in json.load(open(path))["pins"]:
        seen.add((pin["identity"], pin["state"].get("version") or pin["state"]["revision"]))
for identity, version in sorted(seen):
    print(identity, version)
PY
) || { echo "could not read the pins in: $*" >&2; exit 2; }

count=0
missing=0
while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    count=$((count + 1))
    if ! grep -qixF -- "$pin" "$notices" 2>/dev/null; then
        echo "$pin"
        missing=1
    fi
done <<<"$pins"

[ "$count" -gt 0 ] || { echo "no pins in: $*" >&2; exit 2; }
[ "$missing" = 0 ] || exit 1
echo "$count"
