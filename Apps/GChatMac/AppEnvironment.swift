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

    func start() async {
        guard model == nil else { return }
        do {
            let store = try ChatStore.onDisk(at: Self.databasePath())
            // Before a backend is even chosen: this is a fresh process, so
            // nothing is typing and nothing is connected, whatever the file on
            // disk last said. SyncEngine.start() does this too, and a launch
            // that fails before reaching it still has to be honest.
            try store.apply([.clearEphemeralState])
            let selection = try Self.makeBackend()
            let engine = SyncEngine(backend: selection.backend, store: store)
            let model = ChatSessionModel(store: store, engine: engine, me: selection.me)

            try await model.start()
            self.model = model

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
    private static func makeBackend() throws -> Selection {
        guard CommandLine.arguments.contains("--backend=local") else {
            let fixture = FakeBackend(world: .acme)
            return Selection(backend: fixture, me: Acme.alex, fixture: fixture)
        }
        guard let backend = try LocalBridgeBackend.capturing(header: capturedHeader()) else {
            throw ChatError.notAuthenticated
        }
        // Nothing tells us who we are yet - that needs the channel - so no
        // message renders as outgoing. Wrong-looking, and honest.
        return Selection(backend: backend, me: nil, fixture: nil)
    }

    /// Reads a captured `Cookie` header from inside the sandbox container.
    ///
    /// Inside the container on purpose: the app is sandboxed, so a path
    /// anywhere else is denied, and discovering that at the moment someone
    /// tries their first real session would be a bad time to learn it. Copy the
    /// captured header to:
    /// `~/Library/Containers/com.entersprite.gchat/Data/Library/Application Support/GChat/cookie-header.txt`
    private static func capturedHeader() throws -> String {
        let path = try supportDirectory().appendingPathComponent("cookie-header.txt")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            throw ChatError.notAuthenticated
        }
        return raw
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
