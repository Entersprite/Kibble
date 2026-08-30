#!/usr/bin/env bash
# Format Swift sources in place, using the formatter this repo is configured for.
#
# That is SwiftFormat (nicklockwood), whose settings live in `.swiftformat` —
# indent 4, maxwidth 110, before-first wrapping — chosen to agree with
# `.swiftlint.yml`.
#
# NOT Apple's `swift-format`, which ships with Xcode under a confusingly similar
# name. It ignores `.swiftformat` entirely, defaults to 2-space indent, and its
# preferred line breaking puts opening braces on their own line, which
# swiftlint's `opening_brace` rule rejects. Running it reformats every file in
# the repo and leaves `scripts/lint.sh` failing. That is not hypothetical: it
# happened in this project's predecessor, which had no git history to recover
# from. Hence the refusal below rather than a fallback.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftformat > /dev/null; then
    echo "swiftformat is not installed. Install it with:" >&2
    echo "    brew install swiftformat" >&2
    echo "Do not substitute 'xcrun swift-format' — see the comment in this script." >&2
    exit 1
fi

targets=()
for d in Packages Apps Spikes; do [ -d "$d" ] && targets+=("$d"); done
[ ${#targets[@]} -gt 0 ] || { echo "nothing to format yet"; exit 0; }

exec swiftformat "${targets[@]}" --exclude '**/Generated/**,**/.build/**,**/reference/**'
