import ChatKit
import Foundation
import SyncEngine
import Synchronization
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
    /// What the composer's paperclip is answered with.
    var filesToSend: [URL] = []
    var probeReport = "Written to probe.txt."

    /// The clock `makeSession()` hands the engine for the mention backfill.
    /// `nil` is the wall clock, `SessionSelection`'s own default.
    var sessionNow: (@Sendable () -> Date)?

    var hasStoredSessionFailure: (any Error)?
    var forgetFailure: (any Error)?
    var openStoreFailure: (any Error)?
    var eraseFailure: (any Error)?
    var makeSessionFailure: (any Error)?

    /// The knob this fake was missing, and its absence hid half a finding.
    ///
    /// `startDiagnostics()` is the one operation that can throw *after*
    /// `phase = .running(model)` has already been set, which makes it the only
    /// way to reach `.failed` holding a fully connected session. With no way to
    /// make it fail, nothing could reach that state and nothing noticed that
    /// the model was being dropped rather than stopped.
    var startDiagnosticsFailure: (any Error)?

    /// The one store handed out by `openStore()`, so a test can put a row in
    /// it and then assert the erase actually removed it.
    let store: ChatStore
    let backend: FakeLaunchBackend
    /// A fresh directory per fake, under the system's temporary one, so a
    /// test can look at what the attachment cache wrote and what sign-out left.
    let attachmentDirectory = FileManager.default.temporaryDirectory
        .appending(path: "app-core-attachments-\(UUID().uuidString)")
    let driver: RecordingDemoDriver?
    /// The download folder `downloadPlatformFake` places finished files in:
    /// fresh per fake, under the temporary directory, and created only by a
    /// test that downloads, so the fakes that never do leave nothing behind.
    let downloadDirectory = FileManager.default.temporaryDirectory
        .appending(path: "app-core-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// The one platform for this process, as `LaunchServices.downloadPlatform()` requires.
    let downloadPlatformFake: FakeDownloadPlatform

    /// The store's connection state at the instant `makeSession()` was
    /// entered.
    ///
    /// `.clearEphemeralState` must have been applied before a backend exists
    /// to write new state - a fresh process must not inherit the last one's
    /// "connected". Recording the state *at that moment* is what actually
    /// proves the ordering; comparing two call-log indices only proves
    /// `openStore` came before `makeSession`, which is a different claim and
    /// would survive the clear being moved.
    private(set) var connectionStateWhenSessionMade: ConnectionState?

    init(
        arguments: LaunchArguments = LaunchArguments(),
        driver: RecordingDemoDriver? = nil,
        backendCapabilities: Capabilities? = nil
    ) throws {
        self.arguments = arguments
        self.driver = driver
        downloadPlatformFake = FakeDownloadPlatform(folder: downloadDirectory)
        store = try ChatStore.inMemory()
        backend = FakeLaunchBackend(capabilities: backendCapabilities ?? Capabilities(canSendMessages: true))
    }

    func chooseFilesToSend() -> [URL] {
        filesToSend
    }

    func hasStoredSession() async throws -> Bool {
        calls.append(.hasStoredSession)
        if let hasStoredSessionFailure {
            throw hasStoredSessionFailure
        }
        return storedSessionExists
    }

    func forgetStoredSession() async throws {
        // Suspends once before recording, so a concurrent `signOut()` call
        // has a window to interleave with this one - the scenario
        // `AppEnvironment.isSigningOut` exists to make impossible.
        await Task.yield()
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
        connectionStateWhenSessionMade = try? store.connectionState()
        if let makeSessionFailure {
            throw makeSessionFailure
        }
        return SessionSelection(backend: backend, me: nil, driver: driver, now: sessionNow ?? { Date() })
    }

    func runProbe(_ probe: LaunchProbe) async -> String {
        calls.append(.runProbe(probe))
        return probeReport
    }

    func startDiagnostics() throws {
        calls.append(.startDiagnostics)
        if let startDiagnosticsFailure {
            throw startDiagnosticsFailure
        }
    }

    /// Always `nil`: no test here exercises `--probe=markread`, and `AppCore`
    /// must not know or care what a real sink looks like.
    func attachmentCacheDirectory() -> URL? {
        attachmentDirectory
    }

    func markReadTraceSink() -> (any MarkReadTraceSink)? {
        nil
    }

    func downloadPlatform() -> any DownloadPlatform {
        downloadPlatformFake
    }
}

/// A backend that connects, emits nothing, and can be told to fail
/// `connect()` with a chosen error.
///
/// Not `FakeBackend`: this package must not depend on `FixtureBackend`, and
/// the launch tests need a backend whose `connect()` failure mode they choose
/// rather than a world to look at.
final class FakeLaunchBackend: ChatBackend, @unchecked Sendable {
    nonisolated let capabilities: Capabilities

    var connectFailure: (any Error)?

    /// How many times the engine behind this backend was shut down.
    ///
    /// **The only externally observable proof that a session was stopped.**
    /// `SyncEngine.stop()` is `disconnect()`'s sole caller, and
    /// `ChatSessionModel.stopAndEraseStore()` awaits it before touching the
    /// tables - so a launch that erased *around* a live model instead of
    /// through it leaves this at zero. Observed at this seam rather than
    /// through a flag on the fake's `eraseStore()`, so what the assertion
    /// checks is the backend's own lifecycle rather than a route the fix set.
    private(set) var disconnectCount = 0

    private let stream: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation

    /// `holdConnect()`'s state: while `holding`, `connect()` parks its
    /// continuation here until `releaseConnect()`. Behind a lock because
    /// `connect()` runs on the engine's executor, not the test's.
    private struct ConnectHold {
        var holding = false
        var entered = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let hold = Mutex(ConnectHold())

    /// `sent`'s storage. Behind a lock for the same reason as `hold`: `send(_:)`
    /// runs on the engine's executor, and a test reads `sent` from the main actor.
    private let commands = Mutex<[ChatCommand]>([])

    /// What `loadMessages` answers, for any conversation. Behind a lock for
    /// `commands`' reason.
    private let history = Mutex<[Message]>([])

    /// Makes every later `loadMessages` answer `messages` - a newest page
    /// holding more than the store does, which is what tells a mark that
    /// fetched from one that did not.
    func answerHistory(with messages: [Message]) {
        history.withLock { $0 = messages }
    }

    /// Every attachment fetch, as `id/size`. Behind a lock for `commands`' reason.
    private let fetches = Mutex<[String]>([])

    var attachmentFetches: [String] {
        fetches.withLock { $0 }
    }

    /// The protocol's refusing default unless the capability says otherwise,
    /// so a test without it sees exactly what a real backend without it does.
    func attachmentData(_ attachment: Attachment, size: AttachmentSize) async throws -> Data {
        guard capabilities.canFetchAttachments else {
            throw ChatError.unsupported(capability: "canFetchAttachments")
        }
        fetches.withLock { $0.append("\(attachment.id)/\(size.rawValue)") }
        return Data("bytes:\(attachment.id)/\(size.rawValue)".utf8)
    }

    /// `holdDownloads()`'s state, and what the held transfers did. Behind a
    /// lock for `commands`' reason.
    private struct DownloadLog {
        var holding = false
        var entered = 0
        var cancelled = 0
    }

    private let downloadLog = Mutex(DownloadLog())

    /// Makes every later download wait until it is cancelled, so a test can
    /// sign out while one is running.
    func holdDownloads() {
        downloadLog.withLock { $0.holding = true }
    }

    var downloadsEntered: Int {
        downloadLog.withLock { $0.entered }
    }

    var downloadsCancelled: Int {
        downloadLog.withLock { $0.cancelled }
    }

    /// The protocol's refusing default unless the capability says otherwise;
    /// with it, writes "PDF" to `destination`, or holds until cancelled. A
    /// cancelled transfer throws `ChatError.transport`, as the real backend does.
    func downloadAttachment(
        _: Attachment,
        to destination: URL,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        guard capabilities.canDownloadFiles else {
            throw ChatError.unsupported(capability: "canDownloadFiles")
        }
        let holding = downloadLog.withLock { log in
            log.entered += 1
            return log.holding
        }
        if holding {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                downloadLog.withLock { $0.cancelled += 1 }
                throw ChatError.transport("cancelled")
            }
        }
        try Data("PDF".utf8).write(to: destination)
        progress(AttachmentProgress(bytesReceived: 3, totalBytes: 3))
    }

    /// Every command handed to `send(_:)`, for a test to read.
    var sent: [ChatCommand] {
        commands.withLock { $0 }
    }

    init(capabilities: Capabilities = Capabilities(canSendMessages: true)) {
        self.capabilities = capabilities
        (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    }

    nonisolated var events: AsyncStream<ChatEvent> {
        stream
    }

    /// Makes `connect()` wait until `releaseConnect()`, so a test can
    /// look at what a session does while it is still connecting.
    func holdConnect() {
        hold.withLock { $0.holding = true }
    }

    func releaseConnect() {
        let waiter = hold.withLock { state in
            state.holding = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Whether `connect()` has been called at all.
    var connectEntered: Bool {
        hold.withLock { $0.entered }
    }

    func connect() async throws {
        // One lock for "entered", "holding?" and parking, so a release can
        // never land between the check and the wait.
        await withCheckedContinuation { continuation in
            let parked = hold.withLock { state in
                state.entered = true
                guard state.holding else { return false }
                state.waiter = continuation
                return true
            }
            if !parked {
                continuation.resume()
            }
        }
        if let connectFailure {
            throw connectFailure
        }
    }

    /// Holds `disconnect()` after it is counted, so a test can see the escape
    /// from `.failed` take longer than any fixed wait (it took over 100 ms
    /// under the full suite's load, against 2.5 ms alone).
    var disconnectDelay: Duration?

    func disconnect() async {
        disconnectCount += 1
        if let disconnectDelay {
            try? await Task.sleep(for: disconnectDelay)
        }
        continuation.finish()
    }

    /// Delivers an event as if the channel had, for tests that need a session
    /// to see traffic.
    func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }

    func send(_ command: ChatCommand) async throws {
        commands.withLock { $0.append(command) }
    }

    func loadConversations() async throws -> [Conversation] {
        []
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        history.withLock { $0 }
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
