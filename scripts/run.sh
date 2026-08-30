#!/usr/bin/env bash
# Build, then launch the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
./scripts/build.sh
APP="DerivedData/Build/Products/$CONFIG/GChat.app"

if [[ ! -d "$APP" ]]; then
    echo "Build product not found at $APP" >&2
    exit 1
fi

# Relaunching too soon after pkill makes `open` fail with error -600, because
# the old process is still shutting down. Wait for it to actually exit.
if pgrep -x GChat >/dev/null 2>&1; then
    pkill -x GChat || true
    for _ in $(seq 1 50); do
        pgrep -x GChat >/dev/null 2>&1 || break
        read -r -t 0.1 </dev/null || true
    done
fi

open "$APP"
echo "Launched $APP"
