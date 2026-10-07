#!/usr/bin/env bash
# One-off: carry an install's store, notification rules and preferences from
# the GChat-era container (com.entersprite.gchat) into Kibble's
# (com.entersprite.kibble). A sandboxed app cannot read another app's
# container, so this runs outside the app, once, with Kibble quit, after the
# renamed Kibble has launched once (macOS creates its container then).
#
#   ./scripts/migrate-container.sh                              # the real containers
#   KIBBLE_CONTAINERS=/path/to/test-tree ./scripts/migrate-container.sh
set -euo pipefail

fail() {
    echo "migrate-container: $1" >&2
    exit 1
}

root=${KIBBLE_CONTAINERS:-$HOME/Library/Containers}
old=$root/com.entersprite.gchat/Data/Library
new=$root/com.entersprite.kibble/Data/Library

if [[ -z "${KIBBLE_CONTAINERS:-}" ]]; then
    running=$(pgrep -x Kibble || true)
    [[ -z "$running" ]] || fail "quit Kibble first"
fi
[[ -d "$old/Application Support/GChat" ]] || fail "no GChat-era data in $old"
[[ -d "$new" ]] || fail "no Kibble container yet: launch the renamed Kibble once, quit it, then run this again"

# The new install's own folder is moved aside, never copied over: a store's
# -wal journal left beside an older database would be replayed onto it. The
# copy lands in a staging folder first, so a copy that fails (macOS refusing
# Terminal another app's data, say) leaves the new install as it was, rather
# than holding part of the old one.
stamp=$(date +%Y%m%d%H%M%S)
target="$new/Application Support/Kibble"
staging="$target.migrating-$stamp"
mkdir -p "$new/Application Support"
if ! ditto "$old/Application Support/GChat" "$staging"; then
    rm -rf "$staging"
    fail "could not copy $old/Application Support/GChat; nothing was changed"
fi
if [[ -e "$target" ]]; then
    mv "$target" "$target.before-migration-$stamp"
fi
mv "$staging" "$target"

# Preferences are copied as a file, then cfprefsd is restarted so it drops any
# cached copy of the new domain. Not `defaults export | import`: given a path
# under another Library/Preferences, defaults exits 0 and writes nothing
# (measured, session 53), so it would report success and carry nothing.
old_prefs=$old/Preferences/com.entersprite.gchat.plist
new_prefs=$new/Preferences/com.entersprite.kibble.plist
if [[ -f "$old_prefs" ]]; then
    mkdir -p "$new/Preferences"
    if [[ -e "$new_prefs" ]]; then
        mv "$new_prefs" "$new_prefs.before-migration-$stamp"
    fi
    cp "$old_prefs" "$new_prefs"
    if [[ -z "${KIBBLE_CONTAINERS:-}" ]]; then
        killall -u "$USER" cfprefsd 2>/dev/null || true
    fi
fi

echo "Copied the store, notification rules and preferences into Kibble's container."
echo "The GChat-era container is untouched. Once Kibble looks right, delete it with:"
echo "  rm -rf \"$root/com.entersprite.gchat\""
