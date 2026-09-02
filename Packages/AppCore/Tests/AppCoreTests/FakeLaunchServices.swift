import ChatKit
import Foundation
import SyncEngine
@testable import AppCore

/// A `LaunchServices` whose every outcome is settable, and which records the
/// order it was called in.
///
/// **The call log is not decoration.** The guarantee under test in
/// `SignOutAndEraseTests` is about *order* - that nothing may reach the login
/// window before the store has been erased - and an assertion about effects
/// alone cannot see an ordering bug.
@MainActor
final class FakeLaunchServices: LaunchServices {
    enum Call: Equatable {
        case hasStoredSession
        case forgetStoredSession
        case openStore
        case eraseStore
        case makeSession
        case runProbe(LaunchProbe)
        case startDiagnostics
    }

    private(set) var calls: [Call] = []

    var arguments: LaunchArguments

    var storedSessionExists = true
    var probeReport = "Written to probe.txt."

    var hasStoredSessionFailure: (any Error)?
    var forgetFailure: (any Error)?
    var openStoreFailure: (any Error)?
    var eraseFailure: (any Error)?
    var makeSessionFailure: (any Error)?

    /// The one store handed out by `openStore()`, so a test can put a row in
    /// it and then assert the erase actually removed it.
    let store: ChatStore
    let backend: FakeLaunchBackend
    let driver: RecordingDemoDriver?

    init(
        arguments: LaunchArguments = LaunchArguments(),
        driver: RecordingDemoDriver? = nil
    ) throws {
        self.arguments = arguments
        self.driver = driver
        store = try ChatStore.inMemory()
        backend = FakeLaunchBackend()
    }

    func hasStoredSession() async throws -> Bool {
        calls.append(.hasStoredSession)
        if let hasStoredSessionFailure {
            throw hasStoredSessionFailure
        }
        return storedSessionExists
    }

    func forgetStoredSession() async throws {
        calls.append(.forgetStoredSession)
        if let forgetFailure {
            throw forgetFailure
        }
    }

    func openStore() throws -> ChatStore {
        calls.append(.openStore)
        if let openStoreFailure {
            throw openStoreFailure
        }
        return store
    }

    func eraseStore() throws {
        calls.append(.eraseStore)
        if let eraseFailure {
            throw eraseFailure
        }
        try store.erase()
    }

    func makeSession() async throws -> SessionSelection {
        calls.append(.makeSession)
        if let makeSessionFailure {
            throw makeSessionFailure
        }
        return SessionSelection(backend: backend, me: nil, driver: driver)
    }

    func runProbe(_ probe: LaunchProbe) async -> String {
        calls.append(.runProbe(probe))
        return probeReport
    }

    func startDiagnostics() throws {
        calls.append(.startDiagnostics)
    }
}

/// A backend that connects, emits nothing, and can be told to fail
/// `connect()` with a chosen error.
///
/// Not `FakeBackend`: this package must not depend on `FixtureBackend`, and
/// the launch tests need a backend whose `connect()` failure mode they choose
/// rather than a world to look at.
final class FakeLaunchBackend: ChatBackend, @unchecked Sendable {
    nonisolated let capabilities = Capabilities(canSendMessages: true)

    var connectFailure: (any Error)?

    private let stream: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    }

    nonisolated var events: AsyncStream<ChatEvent> {
        stream
    }

    func connect() async throws {
        if let connectFailure {
            throw connectFailure
        }
    }

    func disconnect() async {
        continuation.finish()
    }

    func send(_: ChatCommand) async throws {}
    func loadConversations() async throws -> [Conversation] {
        []
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        []
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}
}

/// Records that it was started and stopped, which is the whole assertion.
final class RecordingDemoDriver: DemoDriver, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
    }
}
