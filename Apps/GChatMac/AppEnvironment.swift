import ChatKit
import DesignSystem
import FixtureBackend
import Foundation
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
            let backend = FakeBackend(world: .acme)
            let store = try ChatStore.onDisk(at: Self.databasePath())
            let engine = SyncEngine(backend: backend, store: store)
            let model = ChatSessionModel(store: store, engine: engine, me: Acme.alex)

            try await model.start()
            self.model = model

            // The demo world does not move on its own. The driver is what makes
            // a launched app look alive rather than like a screenshot.
            let demo = FixtureDemoDriver(backend: backend)
            await demo.start()
            self.demo = demo
        } catch {
            startupError = String(describing: error)
        }
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
            lastError: model.lastError
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
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GChat", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chat.sqlite").path
    }
}
