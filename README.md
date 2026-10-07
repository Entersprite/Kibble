# Kibble

A native Google Chat client for macOS, written in Swift and SwiftUI.

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
by hand from Kibble › Check for Updates…, or on its own at launch, every hour or
every day (Settings › Updates). Updating from an older Kibble that was not yet
notarized, macOS asks once for your login password so Kibble can bring its saved
session along; choose **Always Allow**.
Releases from before updates existed (v2026.41.1 and earlier) have to be
replaced by hand once.

## Build

```bash
./scripts/bootstrap.sh       # checks the toolchain; changes nothing
./scripts/create-dev-cert.sh # once: a stable signing identity, so Keychain access survives rebuilds
./scripts/generate.sh        # generates Kibble.xcodeproj from project.yml
./scripts/build.sh           # builds the app (--fast skips signing)
```

`./scripts/test.sh` runs the architecture checks and every package's tests, and
`./scripts/lint.sh` runs SwiftLint. Both must pass.

## How it was made

Kibble was written with [Claude Code](https://claude.com/claude-code), Anthropic's
AI coding agent, working with its owner. Most commits carry a
`Co-Authored-By: Claude` trailer saying so.

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
