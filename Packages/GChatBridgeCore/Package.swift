// swift-tools-version: 6.0
import PackageDescription

/// The reverse-engineered protocol, and the one package that must compile on
/// Linux so a future bridge server links it verbatim instead of a second
/// implementation being maintained.
///
/// GChatBridgeCore itself touches no network: HTTP goes through the
/// HTTPTransport protocol, so framing, the long-poll state machine and catch-up
/// are pure Swift. URLSessionTransport is the ONLY target that imports
/// networking, which bounds the Linux port to one file by construction.
/// scripts/test.sh enforces both halves of that claim.
let package = Package(
    name: "GChatBridgeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GChatBridgeCore", targets: ["GChatBridgeCore"]),
        .library(name: "URLSessionTransport", targets: ["URLSessionTransport"])
    ],
    dependencies: [
        // Pinned to the generator that produced Generated/: protoc-gen-swift 1.38.1.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0")
    ],
    targets: [
        .target(
            name: "GChatBridgeCore",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "URLSessionTransport",
            dependencies: ["GChatBridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // StubURLProtocol lives here, not in the core: the core is tested
        // against a FakeHTTPTransport with scripted responses, so it needs no
        // URLProtocol at all. Only URLSessionTransportTests does.
        .target(
            name: "GChatBridgeCoreTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GChatBridgeCoreTests",
            dependencies: ["GChatBridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "URLSessionTransportTests",
            dependencies: ["URLSessionTransport", "GChatBridgeCoreTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
