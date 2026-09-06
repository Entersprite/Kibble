// swift-tools-version: 6.2
import PackageDescription

/// The only package that imports `GChatBridgeCore`.
///
/// That containment is the architecture's whole distribution argument: a future
/// iOS binary links `RemoteBackend` instead and therefore contains no
/// reverse-engineered code at all. Keeping this package the sole importer is
/// what makes that claim checkable rather than aspirational.
///
/// macOS only, deliberately. It hosts the protocol in-process, which is the Mac
/// story; iOS gets the same `ChatBackend` from a server.
let package = Package(
    name: "LocalBridgeBackend",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LocalBridgeBackend", targets: ["LocalBridgeBackend"])
    ],
    dependencies: [
        .package(path: "../ChatKit"),
        .package(path: "../GChatBridgeCore")
    ],
    targets: [
        .target(
            name: "LocalBridgeBackend",
            dependencies: [
                "ChatKit",
                .product(name: "GChatBridgeCore", package: "GChatBridgeCore"),
                .product(name: "URLSessionTransport", package: "GChatBridgeCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalBridgeBackendTests",
            dependencies: ["LocalBridgeBackend", "ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
