import Foundation
import LocalBridgeBackend

/// The `--probe=` diagnostics that replace the launch, split out of `AppEnvironment` because they
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
/// `@MainActor` only because `SystemLaunchServices.supportDirectory()` is -
/// every call here already comes from `AppEnvironment.start()`, itself
/// `@MainActor`, so this costs nothing and is not otherwise load-bearing.
@MainActor
enum LaunchProbes {
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

    /// No required arguments: the defaults supply the Keychain store and the
    /// live transport, so this names no core type. Same shape as
    /// `LocalBridgeBackend.using(_:transport:)` at SessionHandoff.swift:77.
    ///
    /// `--probe-conversation=N` picks which conversation the topics/read-
    /// receipts section probes, the same sub-flag shape `AppNapProbe`'s
    /// `--probe-activity`/`--probe-close-window` already use. Omitted, the
    /// report defaults to the most recently active conversation.
    static func apiProbe() async -> String {
        await write(
            APIProbeReport.run(conversationIndexOverride: probeConversationOverride()),
            to: "api-probe.txt"
        )
    }

    /// `--probe=punctual`. Long-running, so the report is rewritten after
    /// every line rather than once at the end: a run that is quit early keeps
    /// what it saw. `--probe-minutes=N` changes the ten-minute default, and
    /// `--punctual-server=` the server path, both parsed here for the reason
    /// `--probe-conversation=` is.
    static func punctualProbe() async -> String {
        let name = "punctual-probe.txt"
        guard let directory = try? SystemLaunchServices.supportDirectory() else {
            return "Could not resolve where to write \(name)."
        }
        let url = directory.appendingPathComponent(name)
        // Clamped: zero ends the run at once, and an absurd value traps.
        let minutes = argument("--probe-minutes=").flatMap(Int.init).map { min(max($0, 1), 120) }
        let text = await PunctualProbeReport.run(
            serverPath: argument("--punctual-server="),
            duration: minutes.map { .seconds($0 * 60) } ?? PunctualProbeReport.defaultDuration,
            flush: { text in try? Data(text.utf8).write(to: url, options: .atomic) }
        )
        return write(text, to: name)
    }

    private static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func probeConversationOverride() -> Int? {
        CommandLine.arguments
            .first { $0.hasPrefix("--probe-conversation=") }
            .flatMap { Int($0.dropFirst("--probe-conversation=".count)) }
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
        guard let directory = try? SystemLaunchServices.supportDirectory() else {
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
