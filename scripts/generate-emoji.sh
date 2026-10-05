#!/usr/bin/env bash
# Regenerate DesignSystem's emoji.json from pinned Unicode and CLDR data
# (reactions spec §4.3).
#
# The JSON is COMMITTED, for the same reason the generated protobuf is: no
# build downloads anything, and a regeneration is a reviewable diff. The
# inputs are pinned here; bump a version deliberately, regenerate, and read
# the diff. The glyph filter in generate-emoji.swift keeps only emoji this
# Mac's Apple Color Emoji draws as one glyph, so the list follows the macOS
# version of whoever runs this.
set -euo pipefail
cd "$(dirname "$0")/.."

UNICODE_VERSION=17.0.0
CLDR_VERSION=48.2.0
OUT=Packages/DesignSystem/Sources/DesignSystem/Resources/emoji.json

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://www.unicode.org/Public/${UNICODE_VERSION}/emoji/emoji-test.txt" -o "$WORK/emoji-test.txt"
curl -fsSL "https://cdn.jsdelivr.net/npm/cldr-annotations-full@${CLDR_VERSION}/annotations/en/annotations.json" \
    -o "$WORK/annotations.json"
curl -fsSL "https://cdn.jsdelivr.net/npm/cldr-annotations-derived-full@${CLDR_VERSION}/annotationsDerived/en/annotations.json" \
    -o "$WORK/derived.json"

mkdir -p "$(dirname "$OUT")"
xcrun swift scripts/generate-emoji.swift "$WORK/emoji-test.txt" "$WORK/annotations.json" "$WORK/derived.json" \
    "$UNICODE_VERSION" "$CLDR_VERSION" "$OUT"
