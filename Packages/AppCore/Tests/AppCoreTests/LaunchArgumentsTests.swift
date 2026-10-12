import Testing
@testable import AppCore

/// Argument parsing, as a pure function over a list.
///
/// The launch machine's first three decisions are all reads of
/// `CommandLine.arguments`, which no test can set. Parsing is therefore split
/// from reading: `parsing(_:)` is pure and tested here, and
/// `fromCommandLine()` is the one-line caller that supplies the real list.
struct LaunchArgumentsTests {
    @Test func theDefaultIsTheLocalBackend() {
        let arguments = LaunchArguments.parsing(["Kibble"])
        #expect(arguments.backend == .local)
    }

    @Test func theFixtureIsOptedIntoByName() {
        #expect(LaunchArguments.parsing(["Kibble", "--backend=fixture"]).backend == .fixture)
    }

    /// Inverted from `--backend=local` on purpose: what a person gets by
    /// double-clicking the app is the real bridge.
    @Test func anUnrecognisedBackendFlagStillMeansTheRealBackend() {
        #expect(LaunchArguments.parsing(["Kibble", "--backend=wat"]).backend == .local)
    }

}
