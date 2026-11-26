// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ServiceClient",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "ServiceClient", targets: ["ServiceClient"])],
    dependencies: [
        .package(path: "../ChatAPI"), .package(path: "../ChatKit"),
        .package(path: "../ChatService"), .package(path: "../SyncEngine"), .package(path: "../FixtureBackend")
    ],
    targets: [
        .target(name: "ServiceClient", dependencies: ["ChatAPI", "ChatKit"]),
        .testTarget(name: "ServiceClientTests", dependencies: [
            "ServiceClient", "ChatService", .product(name: "ChatServiceStorage", package: "ChatService"),
            "SyncEngine",
            "FixtureBackend",
            .product(name: "InProcessChatTransport", package: "ChatAPI")
        ])
    ]
)
