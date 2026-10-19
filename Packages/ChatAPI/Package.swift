// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatAPI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ChatAPI", targets: ["ChatAPI"]),
        .library(name: "InProcessChatTransport", targets: ["InProcessChatTransport"])
    ],
    dependencies: [.package(path: "../ChatKit")],
    targets: [
        .target(name: "ChatAPI", dependencies: ["ChatKit"]),
        .target(name: "InProcessChatTransport", dependencies: ["ChatAPI"]),
        .testTarget(
            name: "ChatAPITests", dependencies: ["ChatAPI", "InProcessChatTransport"],
            resources: [.copy("Golden")]
        )
    ]
)
