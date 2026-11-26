// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatService",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ChatService", targets: ["ChatService"]),
        .library(name: "ChatServiceStorage", targets: ["ChatServiceStorage"])
    ],
    dependencies: [
        .package(path: "../ChatAPI"), .package(path: "../ChatKit"),
        .package(path: "../ChatRules"), .package(path: "../SyncEngine"),
        .package(path: "../FixtureBackend"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "ChatService", dependencies: ["ChatAPI", "ChatKit", "ChatRules"]),
        .target(name: "ChatServiceStorage", dependencies: [
            "ChatService", "ChatAPI", "ChatKit", "ChatRules",
            .product(name: "ChatPersistence", package: "SyncEngine"),
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .testTarget(name: "ChatServiceTests", dependencies: [
            "ChatService", "ChatServiceStorage", "FixtureBackend",
            .product(name: "InProcessChatTransport", package: "ChatAPI")
        ])
    ]
)
