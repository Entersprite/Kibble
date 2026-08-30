# googlechat.proto — provenance

**Source:** `maugclib/googlechat.proto` from [mautrix/googlechat](https://github.com/mautrix/googlechat)
**Retrieved:** 2026-08-30, from `codeload.github.com/mautrix/googlechat/tar.gz/refs/heads/master`
**Size:** 2552 lines, proto2 syntax

## Licence

The surrounding `mautrix-googlechat` project is AGPL-3.0, and its source is **not**
vendored into this repository (`reference/` is gitignored). This `.proto` file
carries its own explicit grant in its header:

> Feel free to use this .proto for whatever you want to, under whatever license you want.

That is why this one file — and only this one file — is committed here.

## What it is, and what it is not

Hand-written by third parties from information extracted from decompiled Android
and iOS Google apps. It is **not** documentation from Google. It describes what
worked for that project at its last release; it is a hypothesis about Google's
current servers, not a specification of them.

Two consequences that matter:

- `oneof`s are commented out throughout (the header explains this was for
  protobuf-c's benefit). Field numbers are still correct, but mutual exclusion
  is not expressed in the generated Swift.
- Absence of a message here does not prove absence of the endpoint. The lack of
  any notification-settings *write* request is the live example: it may simply
  never have been reverse-engineered. Verify against real traffic before
  concluding a capability does not exist.

## Regenerating

`./scripts/generate-proto.sh` — regenerates `Sources/GChatBridgeCore/Generated/`
and records this file's SHA-256 in `.protohash`. `scripts/test.sh` fails if the
recorded hash and the file disagree, so generated Swift can never silently drift
from the proto it came from.
