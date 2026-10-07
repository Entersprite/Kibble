import Testing
@testable import AppCore

/// Argument parsing, as a pure function over a list.
///
/// The launch machine's first three decisions are all reads of
/// `CommandLine.arguments`, which no test can set. Parsing is therefore split
/// from reading: `parsing(_:)` is pure and tested here, and
/// `fromCommandLine()` is the one-line caller that supplies the real list.
struct LaunchArgumentsTests {
    @Test func theDefaultIsTheRealBackendAndNoProbe() {
        let arguments = LaunchArguments.parsing(["Kibble"])
        #expect(arguments.usesRealBackend)
        #expect(arguments.probe == nil)
        #expect(!arguments.runsDiagnostics)
    }

    @Test func theFixtureIsOptedIntoByName() {
        #expect(!LaunchArguments.parsing(["Kibble", "--backend=fixture"]).usesRealBackend)
    }

    /// Inverted from `--backend=local` on purpose: what a person gets by
    /// double-clicking the app is the real bridge.
    @Test func anUnrecognisedBackendFlagStillMeansTheRealBackend() {
        #expect(LaunchArguments.parsing(["Kibble", "--backend=wat"]).usesRealBackend)
    }

    @Test func eachProbeIsRecognised() {
        #expect(LaunchArguments.parsing(["Kibble", "--probe=keychain"]).probe == .keychain)
        #expect(LaunchArguments.parsing(["Kibble", "--probe=api"]).probe == .api)
        #expect(LaunchArguments.parsing(["Kibble", "--probe=punctual"]).probe == .punctual)
        #expect(LaunchArguments.parsing(["Kibble", "--probe=upload"]).probe == .upload)
        #expect(LaunchArguments.parsing(["Kibble", "--probe=people"]).probe == .people)
        #expect(LaunchArguments.parsing(["Kibble", "--probe=edit"]).probe == .edit)
    }

    /// `--probe=appnap` is a different kind of flag: it does not short-circuit
    /// the launch into `.report`, it instruments a launch that proceeds
    /// normally. Conflating the two would stop the app ever starting under it.
    @Test func appNapIsDiagnosticsAndNotAReportProbe() {
        let arguments = LaunchArguments.parsing(["Kibble", "--probe=appnap"])
        #expect(arguments.probe == nil)
        #expect(arguments.runsDiagnostics)
    }
}
