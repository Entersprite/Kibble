import ChatKit
import DesignSystem
import FixtureBackend
import Foundation
import LocalBridgeBackend
import SwiftUI
import SyncEngine

/// Wires one backend to one store to one window.
///
/// The only place in the app that names a concrete backend. Swapping the
/// fixture for `LocalBridgeBackend` is a change to `makeBackend()` and nothing
/// else - which is the property the whole package layout exists to buy, so it
/// is worth keeping literally true.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var model: ChatSessionModel?
    private(set) var startupError: String?

    private var demo: FixtureDemoDriver?
    private let probe = AppNapProbe()

    /// For the menu-bar agent, which has no room for a sidebar.
    var totalUnread: Int {
        (model?.conversations ?? []).reduce(0) { $0 + $1.unreadCount }
    }

    func start() async {
        guard model == nil else { return }
        if Self.isKeychainCheckRequested {
            await runKeychainCheck()
            return
        }
        if Self.isAPIProbeRequested {
            await runAPIProbe()
            return
        }
        do {
            let store = try ChatStore.onDisk(at: Self.databasePath())
            // Before a backend is even chosen: this is a fresh process, so
            // nothing is typing and nothing is connected, whatever the file on
            // disk last said. SyncEngine.start() does this too, and a launch
            // that fails before reaching it still has to be honest.
            try store.apply([.clearEphemeralState])
            let selection = try await Self.makeBackend()
            let engine = SyncEngine(backend: selection.backend, store: store)
            let model = ChatSessionModel(store: store, engine: engine, me: selection.me)

            try await model.start()
            self.model = model

            if AppNapProbe.isRequested {
                try probe.start(writingTo: Self.supportDirectory()
                    .appendingPathComponent("appnap-probe.csv"))
            }

            if let fixture = selection.fixture {
                // The demo world does not move on its own. The driver is what
                // makes a launched app look alive rather than like a screenshot.
                let demo = FixtureDemoDriver(backend: fixture)
                await demo.start()
                self.demo = demo
            }
        } catch {
            // Including a bridge that could not authenticate: the window shows
            // it, because a launch that silently does nothing is the worst
            // possible report.
            startupError = String(describing: error)
        }
    }

    /// `--probe=keychain`, in the shape `AppNapProbe` established.
    ///
    /// Whether a sandboxed app can use the Keychain depends on how it was
    /// signed rather than on anything in this repository, and the failure is a
    /// silent `-34018` that reads exactly like "no session stored". Kept rather
    /// than deleted once it first answered, because the question returns every
    /// time the signing identity does.
    static var isKeychainCheckRequested: Bool {
        CommandLine.arguments.contains("--probe=keychain")
    }

    private func runKeychainCheck() async {
        let result = await KeychainCredentialStore.forSelfCheck().selfCheck()
        startupError = result
        // Written as well as shown: the window is not readable from a script,
        // and this is a check somebody runs after changing how the app is
        // signed.
        if let directory = try? Self.supportDirectory() {
            try? result.write(
                to: directory.appendingPathComponent("keychain-check.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// The `/api/` probe. Same reasoning as the Keychain check: it answers a
    /// question that returns, and it needs the real credential rather than a
    /// hand-pasted header.
    static var isAPIProbeRequested: Bool {
        CommandLine.arguments.contains("--probe=api")
    }

    private func runAPIProbe() async {
        // No arguments: the defaults supply the Keychain store and the live
        // transport, so the app names no core type. Same shape as
        // `LocalBridgeBackend.using(_:transport:)` at SessionHandoff.swift:77.
        let report = await APIProbeReport.run()
        startupError = report
        // Written as well as shown, for the same reason the Keychain check is:
        // the window is not readable from a script, and this report is meant to
        // be pasted into findings.md.
        if let directory = try? Self.supportDirectory() {
            try? report.write(
                to: directory.appendingPathComponent("api-probe.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private struct Selection {
        let backend: any ChatBackend
        let me: Member.ID?
        /// Non-nil only for the fixture, which is the one that needs driving.
        let fixture: FakeBackend?
    }

    /// The only place in the repo that picks a backend.
    ///
    /// `--backend=local` hosts `GChatBridgeCore` in-process through
    /// `LocalBridgeBackend`; anything else gets the fixture. Defaulting to the
    /// fixture is deliberate: launching the app must never touch a Google
    /// account by accident.
    private static func makeBackend() async throws -> Selection {
        guard CommandLine.arguments.contains("--backend=local") else {
            let fixture = FakeBackend(world: .acme)
            return Selection(backend: fixture, me: Acme.alex, fixture: fixture)
        }
        // The session comes from the Keychain, put there by the login window.
        // There is no longer a file to copy: a live Google session in plain
        // text inside the container was the developer escape hatch, and this
        // is what retired it.
        let backend: LocalBridgeBackend?
        do {
            backend = try await LocalBridgeBackend.using(KeychainCredentialStore())
        } catch {
            // A Keychain that refuses is not an absent credential, and reporting
            // it as one would send someone through a two-factor login that
            // cannot fix it.
            throw ChatError.unknown(KeychainDiagnosis.explain(error))
        }
        guard let backend else {
            throw ChatError.unknown(
                "No session in the Keychain. Open the login window and sign in."
            )
        }
        // Nothing tells us who we are yet - that needs the channel - so no
        // message renders as outgoing. Wrong-looking, and honest.
        return Selection(backend: backend, me: nil, fixture: nil)
    }

    var sceneState: ChatSceneState {
        guard let model else {
            return ChatSceneState(
                lastError: startupError.map { ChatError.unknown($0) }
            )
        }
        return ChatSceneState(
            conversations: model.conversations,
            directory: model.directory,
            me: model.me,
            selected: model.selected,
            messages: model.messages,
            typing: model.typing,
            connection: model.connectionState,
            lastError: model.lastError,
            capabilities: model.capabilities
        )
    }

    var actions: ChatSceneActions {
        ChatSceneActions(
            select: { [weak self] id in self?.model?.select(id) },
            send: { [weak self] text in self?.model?.send(text) }
        )
    }

    /// `~/Library/Application Support/GChat/chat.sqlite`.
    ///
    /// On disk rather than in memory even though the backend is a fixture:
    /// instant cold launch is one of the three things the store exists for, and
    /// the fixture's identifiers are deterministic, so relaunching upserts the
    /// same rows instead of duplicating them.
    private static func databasePath() throws -> String {
        try supportDirectory().appendingPathComponent("chat.sqlite").path
    }

    private static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GChat", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
