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
    private(set) var phase: LaunchPhase = .loading

    private var demo: FixtureDemoDriver?
    private let probe = AppNapProbe()

    /// For the menu-bar agent, which has no room for a sidebar.
    var totalUnread: Int {
        guard case let .running(model) = phase else { return 0 }
        return model.conversations.reduce(0) { $0 + $1.unreadCount }
    }

    func start() async {
        if case .running = phase {
            return
        }
        if Self.isKeychainCheckRequested {
            await runKeychainCheck()
            return
        }
        if Self.isAPIProbeRequested {
            await runAPIProbe()
            return
        }
        do {
            // Asked before anything is built. A launch with no stored session
            // is not an error and must not be reported as one - it is a first
            // run, and the only sensible thing to show is a sign-in.
            if Self.isRealBackendRequested, try await Self.storedSession() == nil {
                phase = .needsSignIn(reason: nil)
                return
            }
            let store = try ChatStore.onDisk(at: Self.databasePath())
            // Before a backend is even chosen: this is a fresh process, so
            // nothing is typing and nothing is connected, whatever the file on
            // disk last said.
            try store.apply([.clearEphemeralState])
            let selection = try await Self.makeBackend()
            let engine = SyncEngine(backend: selection.backend, store: store)
            let model = ChatSessionModel(store: store, engine: engine, me: selection.me)

            try await model.start()
            phase = .running(model)

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
        } catch ChatError.notAuthenticated {
            // The one error that is not a failure: the credential is there and
            // Google has stopped accepting it. Expiry never proves this and
            // never disproves it (`findings.md` §11), so it is only knowable
            // from a round trip - and this is that round trip having happened.
            phase = .needsSignIn(reason: "Your Google session stopped working. Sign in again.")
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// What is in the Keychain, or `nil`. Throws rather than returning `nil`
    /// when the Keychain refuses: "no credential" and "could not look" lead to
    /// opposite recoveries, and collapsing them sends someone through a
    /// two-factor login that cannot possibly help.
    private static func storedSession() async throws -> StoredSessionSummary? {
        do {
            return try await KeychainCredentialStore().summary(at: Date())
        } catch {
            throw ChatError.unknown(KeychainDiagnosis.explain(error))
        }
    }

    /// Called by the login window once a capture has reached the Keychain.
    /// Re-runs `start()`, which now finds a session where a moment ago there
    /// was none - so signing in connects rather than printing "relaunch me".
    func signedIn() async {
        phase = .loading
        await start()
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
        let store = KeychainCredentialStore.forSelfCheck()
        let legacy = await store.selfCheck()
        let modern = await store.dataProtectionSelfCheck()
        let result = """
        legacy keychain:          \(legacy)
        data-protection keychain: \(modern)
        """
        // A phase, not a bare string. Nothing but `phase` decides what is on
        // screen, so a probe that only wrote a property left the window on
        // `loading`'s spinner for ever - the report was on disk and the person
        // running it had no way to know it had even finished.
        phase = .report(result)
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
        phase = .report(report)
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

    /// Whether the real bridge was asked for - now the default.
    ///
    /// Inverted from `--backend=local` deliberately. The fixture stays
    /// reachable because `scripts/test.sh` enforces that this app consumes
    /// `FixtureBackend`, and because a fake backend with every capability on is
    /// the only way the degradation paths in `ChatWindow` are exercised at all.
    /// What changes is which one a person gets by double-clicking the app.
    static var isRealBackendRequested: Bool {
        !CommandLine.arguments.contains("--backend=fixture")
    }

    /// The only place in the repo that picks a backend.
    ///
    /// Anything but `--backend=fixture` hosts `GChatBridgeCore` in-process
    /// through `LocalBridgeBackend`, using whatever session `start()` already
    /// confirmed is in the Keychain.
    private static func makeBackend() async throws -> Selection {
        guard isRealBackendRequested else {
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
        // nil is only the instant before the answer, not a standing gap: the
        // bridge does not know who we are synchronously the way the fixture's
        // world does, but `connect()` starts `get_self_user_status` in the
        // background and `ChatSessionModel.me` now watches the store for it,
        // so a message renders as incoming for one heartbeat and then
        // correctly as outgoing - never a session-long "wrong-looking".
        return Selection(backend: backend, me: nil, fixture: nil)
    }

    var sceneState: ChatSceneState {
        guard case let .running(model) = phase else {
            return ChatSceneState(
                lastError: nonRunningErrorMessage.map { ChatError.unknown($0) }
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

    /// What `sceneState` shows in the status strip when nothing is running.
    ///
    /// Both non-running phases that have anything to say carry their own text,
    /// and there is no fallback property behind them: "a launch that silently
    /// does nothing is the worst possible report" is exactly the failure this
    /// exists to prevent, and a second source for the same line is how the
    /// probe branches came to write one nothing read.
    private var nonRunningErrorMessage: String? {
        switch phase {
        case let .failed(message), let .report(message): message
        case .loading, .needsSignIn, .running: nil
        }
    }

    var actions: ChatSceneActions {
        ChatSceneActions(
            select: { [weak self] id in
                guard case let .running(model) = self?.phase else { return }
                model.select(id)
            },
            send: { [weak self] text in
                guard case let .running(model) = self?.phase else { return }
                model.send(text)
            },
            // Offered **only** from `.failed`, which is the phase that had no
            // way out. `.needsSignIn` already shows the capture window,
            // `.running` must not invite someone to re-authenticate a working
            // session over one transient banner, and a probe report is not a
            // session problem at all.
            signIn: isFailed ? { [weak self] in self?.requestSignIn() } : nil
        )
    }

    private var isFailed: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    /// The way back to sign-in from a launch that failed.
    ///
    /// Before this, `.needsSignIn` was reachable from exactly two inputs - no
    /// stored session, and `ChatError.notAuthenticated` - and task 3 deleted
    /// the `--login` flag that used to reach the capture window directly.
    /// Everything else landed in `.failed` and stayed there: a page-shape
    /// change (`findings.md` §18), a client refused as an unsupported browser
    /// (where re-capturing with a different user agent is the actual fix), a
    /// `StoredSession` that no longer decodes. Each reproduces on every
    /// relaunch, and the only escape was deleting a Keychain item by hand -
    /// which is not something this app's intended user can do.
    ///
    /// The reason carried forward is the failure itself, so the capture window
    /// says what went wrong rather than implying the person did something.
    private func requestSignIn() {
        guard case let .failed(message) = phase else { return }
        phase = .needsSignIn(reason: message)
    }

    /// One database per backend, and that separation is load-bearing.
    ///
    /// On disk rather than in memory even though the backend is a fixture:
    /// instant cold launch is one of the three things the store exists for, and
    /// the fixture's identifiers are deterministic, so relaunching upserts the
    /// same rows instead of duplicating them.
    ///
    /// **But the views observe the store, not the backend**, so a single file
    /// shared between the two means the fixture's invented conversations are
    /// still on screen the next time a real session launches - indistinguishable
    /// from real ones, because by then nothing on screen remembers where a row
    /// came from. That is not a stale cache; it is fabricated data presented as
    /// a person's actual chats, and it was observed happening. Two files, so it
    /// cannot.
    private static func databasePath() throws -> String {
        let name = isRealBackendRequested ? "chat-local.sqlite" : "chat-fixture.sqlite"
        return try supportDirectory().appendingPathComponent(name).path
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
