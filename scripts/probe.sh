#!/usr/bin/env bash
# Run the Swift bootstrap probe against a captured cookie header.
#
# There is no Package.swift at the repo root - all logic lives in Packages/, so
# `swift run` has to happen inside one of them. That is what this script is for:
# `swift run gchat-probe` from the root fails with "Could not find Package.swift".
#
# Bootstrap only. It does NOT call register, so unlike the Python channel probes
# it cannot rotate COMPASS and cannot disturb a browser session.
#
# Needs ~/.gchat-probe-cookie-header.txt - see docs/protocol/cookie-capture.md.
# Environment passed through to the probe:
#   GCHAT_ACCOUNT_INDEX=1|none      try one specific account shape
#   GCHAT_COOKIE_HEADER_PATH=path   read the header from somewhere else
set -euo pipefail
cd "$(dirname "$0")/.."

cd Packages/GChatBridgeCore
exec swift run gchat-probe "$@"
