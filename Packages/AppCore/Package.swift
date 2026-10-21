// swift-tools-version: 6.2
import PackageDescription

/// The app, minus the platform.
///
/// Holds the launch state machine, the phase-to-scene mapping and the
/// `LaunchServices` protocol. **Names no backend and no credential store** -
/// deliberately, and checked by `scripts/test.sh`. A future iOS app links this
/// package plus `RemoteBackend`; `MacHost` is the half iOS does not link, so
/// the iOS binary carries no reverse-engineered code. Putting a concrete
/// backend in here would either break that or force iOS to reimplement the
/// launch machine - see the design doc §3.1.
let package = Package(
    name: "AppCore",
    // Status and failure text shown to the person is written in English, the
    // only language so far. Resources/Localizable.xcstrings is the String
    // Catalog, read with String(localized: "…", bundle: #bundle). The resource
    // bundle is also what lets `#bundle` compile here: in a target without
    // one, SwiftPM makes the macro an error.
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(path: "../ChatKit"),
        .package(path: "../ChatAPI"),
        .package(path: "../ServiceClient"),
        .package(path: "../SyncEngine"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: ["ChatKit", "ChatAPI", "ServiceClient", "SyncEngine", "DesignSystem"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "ChatKit", "ChatAPI", "ServiceClient", "SyncEngine", "DesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
