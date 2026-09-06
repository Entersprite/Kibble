// swift-tools-version: 6.2
import PackageDescription

/// THE SEAM. This package depends on nothing, and that is enforced structurally
/// rather than by convention: `dependencies: []` is a claim the compiler keeps,
/// and scripts/test.sh additionally asserts these sources import only Foundation.
/// A future RemoteBackend, living outside this repo, depends on ChatKit alone -
/// which is the entire point of a seam.
///
/// FakeBackend does NOT live here. It goes in Packages/FixtureBackend, its own
/// package depending on ChatKit only, because the app consumes it in Debug via
/// --backend=fake and so it is not test-only. Keeping it out of this manifest
/// also preserves the compile-enforced blindness test: if a fake backend cannot
/// be written against ChatKit alone, the seam has leaked.
let package = Package(
    name: "ChatKit",
    // Deliberately low, as portability pressure rather than for compatibility:
    // a brand-new Darwin-only API then fails to compile here.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ChatKit", targets: ["ChatKit"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ChatKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "ChatKitTests",
            dependencies: ["ChatKit"],
            // The wire format's golden files. Declared so they reach the test
            // bundle - and so SwiftPM stops warning that a directory of JSON
            // inside a target is unhandled, which it does for any undeclared
            // file. They are data, not sources: nothing here links them.
            resources: [.copy("Golden")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
