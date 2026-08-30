#!/usr/bin/env bash
# Regenerate Swift from googlechat.proto and record the proto's hash.
#
# The generated Swift is COMMITTED, deliberately. A SwiftPM build-tool plugin
# would make protoc a hard dependency of every build and of any CI, for a file
# that changes maybe twice a year. Committed output is also greppable, which is
# worth a great deal while reverse-engineering and constantly asking "what field
# number is that?".
set -euo pipefail
cd "$(dirname "$0")/.."

PROTO=Packages/GChatBridgeCore/Protos/googlechat.proto
OUT=Packages/GChatBridgeCore/Sources/GChatBridgeCore/Generated
HASH=Packages/GChatBridgeCore/Protos/.protohash

command -v protoc >/dev/null || { echo "protoc missing: brew install protobuf" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || {
    echo "protoc-gen-swift missing: brew install swift-protobuf" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.pb.swift
protoc --proto_path="$(dirname "$PROTO")" \
       --swift_out="$OUT" --swift_opt=Visibility=Public \
       "$PROTO"

shasum -a 256 "$PROTO" | awk '{print $1}' > "$HASH"

echo "generated $(wc -l < "$OUT"/googlechat.pb.swift | tr -d ' ') lines -> $OUT"
echo "recorded proto sha256 -> $HASH"
