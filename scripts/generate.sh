#!/usr/bin/env bash
# Regenerate GChat.xcodeproj from project.yml. Run after changing project.yml
# or adding files outside the SwiftPM package.
set -euo pipefail
cd "$(dirname "$0")/.."
exec xcodegen generate
