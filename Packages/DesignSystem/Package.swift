// swift-tools-version: 6.2
import PackageDescription

/// The views.
///
/// Depends on `ChatKit` and nothing else - not on `SyncEngine`, not on a
/// backend. A view is handed values and hands back callbacks, so it can be
/// rendered from a literal in a preview or a test without a database or a
/// network anywhere near it. The app wires it to a store.
let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        .package(path: "../ChatKit")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: ["ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
