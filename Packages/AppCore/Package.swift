// swift-tools-version: 6.0
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
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(path: "../ChatKit"),
        .package(path: "../SyncEngine"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: ["ChatKit", "SyncEngine", "DesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "ChatKit", "SyncEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
