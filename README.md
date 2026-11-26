# Kibble

A native Google Chat client for macOS, written in Swift and SwiftUI.

Visit [kibble.chat](https://kibble.chat/) for screenshots, features, and installation instructions.

Kibble is **unofficial** and is not affiliated with or endorsed by Google. It
does not use the public Chat REST API. It speaks the same internal protocol as
Chat on the web (protobuf over WebChannel, authenticated with the browser
session's cookies), which was worked out by reading traffic. Google can change
that protocol at any time, and when it does, Kibble breaks until it is updated.

## Requirements

- macOS 26 or later
- Xcode 26
- Homebrew: `brew install xcodegen xcbeautify swiftlint swiftformat swift-protobuf`

## Install

Download the zip from the latest
[release](https://github.com/Entersprite/Kibble/releases/latest), unzip it, and
drag Kibble into Applications in Finder. Kibble is signed with a Developer ID
and notarized by Apple.

From then on Kibble updates itself through [Sparkle](https://sparkle-project.org):
by hand from Kibble › Check for Updates…, or on its own at launch and every hour,
day or week (Settings › Updates). An update found on its own downloads in the
background and installs when you quit Kibble, or right away from Kibble ›
Restart to Update. Updating from an older Kibble that was not yet notarized,
macOS asks once for your login password so Kibble can bring its saved session
along; choose **Always Allow**.
Releases from before updates existed (v2026.41.1 and earlier) have to be
replaced by hand once.

## Build

```bash
./scripts/bootstrap.sh       # checks the toolchain; changes nothing
./scripts/create-dev-cert.sh # once: a stable signing identity, so Keychain access survives rebuilds
./scripts/generate.sh        # generates Kibble.xcodeproj from project.yml
./scripts/build.sh           # builds the app (--fast skips signing)
```

`./scripts/test.sh` runs the architecture checks and each package's quiet tests, and
`./scripts/lint.sh` runs SwiftLint. Both must pass.

Tests that display native windows, sheets or floating panels are disabled by
default, including with a direct `swift test`. Run `./scripts/test.sh --ui` for
those desktop checks, or `./scripts/test.sh --all` for the complete test gate.
The visible tests run one suite at a time under a shared per-user lock, so runs
from separate checkouts cannot overlap. Quiet runs still compile those tests and
report them as skipped. For a direct focused desktop test, explicitly set
`KIBBLE_VISIBLE_UI_TESTS=1`; use the script when sharing a desktop with other runs.

## Demo mode

After a Debug build, open Kibble with a fictional studio workspace:

```sh
open -n DerivedData/Build/Products/Debug/Kibble.app --args --backend=fixture
```

The demo includes conversations, threads, meetings, reactions, mentions, link
previews, app cards and bundled images/documents. It needs no Google account
and keeps its database and attachment cache separate from live chats. Calls
are simulated without microphone, camera or screen capture.

## How it was made

Kibble is built by its owner with [Claude Code](https://claude.com/claude-code),
Anthropic's AI coding agent, and [Codex](https://openai.com/codex/), OpenAI's AI
coding agent. Both contribute to development and maintenance. Most commits
carry a `Co-Authored-By: Claude` trailer crediting Claude's contributions.

## License

MIT. See [LICENSE](LICENSE). Kibble includes Sparkle, GRDB.swift and
SwiftProtobuf, and their licenses are in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and in Help ›
Acknowledgments.

## Disclaimer

Kibble is provided as is, without warranty of any kind. In no event will its
authors be held liable for any damages arising from its use, including to your
Google account. Google has not approved Kibble, and you use it at your own risk.

Google Chat is a trademark of Google LLC. Kibble is not affiliated with or
endorsed by Google.
