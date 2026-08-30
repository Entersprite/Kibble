#!/usr/bin/env bash
# Lint. --strict promotes warnings to errors so a clean exit really means clean.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swiftlint lint --strict --quiet
