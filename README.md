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

## Build

```bash
./scripts/bootstrap.sh       # checks the toolchain; changes nothing
./scripts/create-dev-cert.sh # once: a stable signing identity, so Keychain access survives rebuilds
./scripts/generate.sh        # generates GChat.xcodeproj from project.yml
./scripts/build.sh           # builds the app (--fast skips signing)
```

`./scripts/test.sh` runs the architecture checks and every package's tests, and
`./scripts/lint.sh` runs SwiftLint. Both must pass.

The repository, packages and bundle ID still use the project's earlier name,
GChat.

## How it was made

Kibble was written with [Claude Code](https://claude.com/claude-code), Anthropic's
AI coding agent, working with its owner. Most commits carry a
`Co-Authored-By: Claude` trailer saying so.
