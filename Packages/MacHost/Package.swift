// swift-tools-version: 6.2
import PackageDescription

/// The macOS half of the app shell.
///
/// Conforms `AppCore`'s `LaunchServices` by naming the concrete things: the
/// Keychain, two backends, a container path. Also holds the login web view's
/// seam and the cookie-capture model, because draining a web view into the
/// Keychain is something only the sovereign-Mac tier ever does - the
/// iOS-via-server tier has the server hold the session.
///
/// **This is the package a future iOS app does not link.** That is what keeps
/// `AppCore` reusable and the iOS binary free of reverse-engineered code.
let package = Package(
    name: "MacHost",
    // The host's windows, menus and alerts are written in English, the only
    // language so far. Resources/Localizable.xcstrings is the String Catalog;
    // as in DesignSystem, text meant for it passes `bundle: #bundle`, because
    // SwiftUI and String(localized:) otherwise look in the app's main bundle.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacHost", targets: ["MacHost"])
    ],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../ChatKit"),
        .package(path: "../SyncEngine"),
        .package(path: "../DesignSystem"),
        .package(path: "../FixtureBackend"),
        .package(path: "../LocalBridgeBackend"),
        .package(path: "../ChatAPI"),
        .package(path: "../ChatService"),
        .package(path: "../ServiceClient"),
        // The updater: check, download, EdDSA check, sandboxed install. Imported by
        // SparkleUpdater.swift alone (scripts/test.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // Native peer connections stay in the platform host. Pin the binary
        // distribution so a framework update is an explicit build decision.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.3")
    ],
    targets: [
        .target(
            name: "MacHost",
            dependencies: [
                "AppCore",
                "ChatKit",
                "SyncEngine",
                "DesignSystem",
                "FixtureBackend",
                "LocalBridgeBackend",
                "ChatAPI",
                "ChatService", "ServiceClient",
                .product(name: "ChatServiceStorage", package: "ChatService"),
                .product(name: "InProcessChatTransport", package: "ChatAPI"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")
            ],
            // Kibble's own ringtone (`Ringtone.bundled`), the call and message
            // sounds, and the String Catalog.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacHostTests",
            dependencies: ["MacHost", "AppCore", "ChatKit", "LocalBridgeBackend", "ChatAPI", "ChatService"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
