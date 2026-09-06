// swift-tools-version: 6.2
import PackageDescription

/// THE SEAM'S SECOND IMPLEMENTATION, and the reason it is a package rather than
/// a test helper.
///
/// `dependencies` below is the whole point: `FakeBackend` conforms to
/// `ChatBackend` while seeing ChatKit and nothing else. If a fake backend ever
/// cannot be written that way, a bridge concept has leaked into the domain and
/// this manifest stops compiling - which is a better alarm than a code review.
///
/// It is also not test-only. The Mac app consumes it in Debug (`--backend=fake`)
/// so the UI can be built and demonstrated with no Google account, no cookies
/// and no network, which is why it does not live inside ChatKitTests.
let package = Package(
    name: "FixtureBackend",
    // Matched to ChatKit deliberately: the same portability pressure, and a
    // fake that compiled on a newer floor than the seam would be useless.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "FixtureBackend", targets: ["FixtureBackend"])
    ],
    dependencies: [
        .package(path: "../ChatKit")
    ],
    targets: [
        .target(
            name: "FixtureBackend",
            dependencies: ["ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FixtureBackendTests",
            dependencies: ["FixtureBackend", "ChatKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
