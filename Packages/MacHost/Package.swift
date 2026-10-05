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
        // The updater: check, download, EdDSA check, sandboxed install. Imported by
        // SparkleUpdater.swift alone (scripts/test.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
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
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacHostTests",
            dependencies: ["MacHost", "AppCore", "ChatKit", "LocalBridgeBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
