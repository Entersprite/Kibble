#!/usr/bin/env bash
# The one place the development signing identity is named.
#
# Why this file exists: build.sh, bootstrap.sh and create-dev-cert.sh each
# named it independently, and two of them agreed on a different name than
# build.sh did. Neither name was a substring of the other, so
# build.sh's `grep -q` failed open and fell back to ad-hoc signing - which
# produces a new code hash every build, which is exactly what makes macOS
# re-prompt for the login password on every Keychain read (see the header of
# create-dev-cert.sh). A silent fallback to the failure mode a script exists
# to prevent is worth one file to make impossible.
#
# Sourced, not executed. It sets one variable and defines the two functions
# that find the owner's Developer ID, and runs nothing.

KIBBLE_DEV_IDENTITY="Kibble Dev"

# The one "Developer ID Application: Name (TEAMID)" identity with its private
# key in the Keychain, found at run time so no name or Team ID is written into
# the repository. Prints nothing when there is none. Two or more are an error
# unless KIBBLE_DEVELOPER_ID names one: picking silently could sign a release
# with the wrong team.
developer_id_identity() {
    if [[ -n "${KIBBLE_DEVELOPER_ID:-}" ]]; then
        echo "$KIBBLE_DEVELOPER_ID"
        return 0
    fi
    local listing found count
    listing=$(security find-identity -v -p codesigning 2>/dev/null || true)
    found=$(sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application: .+ \([A-Z0-9]{10}\))"$/\1/p' \
        <<<"$listing" | sort -u)
    count=$(grep -c . <<<"$found" || true)
    if [[ "$count" -gt 1 ]]; then
        echo "dev-identity: $count Developer ID Application identities; set KIBBLE_DEVELOPER_ID to one" >&2
        return 1
    fi
    echo "$found"
}

# "Developer ID Application: Name (TEAMID)" -> TEAMID
team_of_identity() {
    sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$1"
}
