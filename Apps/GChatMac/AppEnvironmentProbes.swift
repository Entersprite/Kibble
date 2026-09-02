import Foundation
import LocalBridgeBackend

/// The two `--probe=` diagnostics, split out of `AppEnvironment` because they
/// are self-contained - reachable only behind a flag, and touching neither
/// `phase` nor the store directly.
///
/// `keychainCheck()` and `apiProbe()` each write their own full report to
/// disk unchanged and return the short confirmation that
/// `LaunchPhase.report` shows instead - see that case's own doc comment for
/// why the whole report no longer goes on screen. `AppEnvironment` is what
/// turns the returned string into `phase = .report(...)`, since only it may
/// set `phase` at all.
///
/// `@MainActor` only because `AppEnvironment.supportDirectory()` is - every
/// call here already comes from `AppEnvironment.start()`, itself
/// `@MainActor`, so this costs nothing and is not otherwise load-bearing.
@MainActor
enum AppEnvironmentProbes {
    /// `--probe=keychain`, in the shape `AppNapProbe` established.
    ///
    /// Whether a sandboxed app can use the Keychain depends on how it was
    /// signed rather than on anything in this repository, and the failure is
    /// a silent `-34018` that reads exactly like "no session stored". Kept
    /// rather than deleted once it first answered, because the question
    /// returns every time the signing identity does.
    static var isKeychainCheckRequested: Bool {
        CommandLine.arguments.contains("--probe=keychain")
    }

    /// The `/api/` probe. Same reasoning as the Keychain check: it answers a
    /// question that returns, and it needs the real credential rather than a
    /// hand-pasted header.
    static var isAPIProbeRequested: Bool {
        CommandLine.arguments.contains("--probe=api")
    }

    static func keychainCheck() async -> String {
        let store = KeychainCredentialStore.forSelfCheck()
        let legacy = await store.selfCheck()
        let modern = await store.dataProtectionSelfCheck()
        let result = """
        legacy keychain:          \(legacy)
        data-protection keychain: \(modern)
        """
        return write(result, to: "keychain-check.txt")
    }

    /// No arguments: the defaults supply the Keychain store and the live
    /// transport, so this names no core type. Same shape as
    /// `LocalBridgeBackend.using(_:transport:)` at SessionHandoff.swift:77.
    static func apiProbe() async -> String {
        await write(APIProbeReport.run(), to: "api-probe.txt")
    }

    /// Writes a probe's full report to `name` beside the app's database, and
    /// returns the short line `LaunchPhase.report` shows instead of the
    /// report itself.
    ///
    /// The line names what actually happened rather than assuming the write
    /// landed: a probe report is pasted into `findings.md` by hand, and a
    /// confirmation that lied about where the text went would send someone
    /// looking for a file that is not there.
    private static func write(_ text: String, to name: String) -> String {
        guard let directory = try? AppEnvironment.supportDirectory() else {
            return "Could not resolve where to write \(name)."
        }
        do {
            try text.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
            return "Written to \(name)."
        } catch {
            return "Could not write \(name): \(error.localizedDescription)"
        }
    }
}
