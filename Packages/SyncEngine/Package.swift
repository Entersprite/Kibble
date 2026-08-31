// swift-tools-version: 6.0
import PackageDescription

/// The store the UI observes, and the reducer that fills it.
///
/// `SyncReducer` is pure and imports no database, which is what lets the future
/// bridge server run the identical reduction rather than a second one written
/// to match - the architecture design's condition for read state and history
/// not drifting into two sources of truth.
///
/// The test target depends on FixtureBackend so the end-to-end test can drive a
/// real `ChatBackend`. That dependency is test-only: the shipping library knows
/// about `ChatKit` and a database, and nothing about any particular backend.
let package = Package(
    name: "SyncEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"])
    ],
    dependencies: [
        .package(path: "../ChatKit"),
        .package(path: "../FixtureBackend")
    ],
    targets: [
        .target(
            name: "SyncEngine",
            dependencies: ["ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine", "ChatKit", "FixtureBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
