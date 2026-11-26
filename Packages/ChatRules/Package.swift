// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatRules",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "ChatRules", targets: ["ChatRules"])],
    dependencies: [.package(path: "../ChatKit")],
    targets: [
        .target(name: "ChatRules", dependencies: ["ChatKit"]),
        .testTarget(name: "ChatRulesTests", dependencies: ["ChatRules"])
    ]
)
