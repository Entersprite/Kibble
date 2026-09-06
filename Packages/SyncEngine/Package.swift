// swift-tools-version: 6.2
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
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"])
    ],
    dependencies: [
        .package(path: "../ChatKit"),
        // Pinned to a major version: GRDB is the store, and a silent major
        // upgrade would rewrite migration semantics under a shipped database.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../FixtureBackend")
    ],
    targets: [
        .target(
            name: "SyncEngine",
            dependencies: ["ChatKit", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine", "ChatKit", "FixtureBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
