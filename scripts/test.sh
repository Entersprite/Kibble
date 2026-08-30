#!/usr/bin/env bash
# Run the unit suite. All real logic lives in the SwiftPM package, so this
# needs no Xcode project, no simulator, and no Google account.
set -euo pipefail
cd "$(dirname "$0")/../Packages/GChatKit"
exec swift test "$@"
