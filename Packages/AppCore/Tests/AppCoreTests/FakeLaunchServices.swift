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
        case eraseBackendCaches
        case makeSession
        case runLaunchReport
        case startDiagnostics
    }

    private(set) var calls: [Call] = []

    var arguments: LaunchArguments

    var storedSessionExists = true
    var launchReportRequested = false
    var diagnosticsRequested = false
    var messageFeedbackCount = 0
    func messageSending() {
        messageFeedbackCount += 1
    }

    var probeReport = "Written to probe.txt."

    /// The clock `makeSession()` hands the engine for the mention backfill.
    /// `nil` is the wall clock, `SessionSelection`'s own default.
    var sessionNow: (@Sendable () -> Date)?
    var sessionConnectionService: ConnectionService?
    var sessionAudioCalls: (any AudioCallService)?
    /// Successive sign-ins can create genuinely separate backend/service owners.
    var sessionSelections: [SessionSelection] = []

    var hasStoredSessionFailure: (any Error)?
    var forgetFailure: (any Error)?
    var openStoreFailure: (any Error)?
    var eraseFailure: (any Error)?
    var eraseBackendCachesFailure: (any Error)?
    /// The backend's disconnect count at each backend-cache erase, because a
    /// backend may save its caches while it disconnects.
    private(set) var disconnectsWhenBackendCachesErased: [Int] = []
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
        backendCapabilities: Capabilities? = nil,
        existingStore: ChatStore? = nil
    ) throws {
        self.arguments = arguments
        self.driver = driver
        downloadPlatformFake = FakeDownloadPlatform(folder: downloadDirectory)
        store = try existingStore ?? ChatStore.inMemory()
        backend = FakeLaunchBackend(capabilities: backendCapabilities ?? Capabilities(canSendMessages: true))
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

    func eraseBackendCaches() throws {
        calls.append(.eraseBackendCaches)
        disconnectsWhenBackendCachesErased.append(backend.disconnectCount)
        if let eraseBackendCachesFailure {
            throw eraseBackendCachesFailure
        }
    }

    func makeSession() async throws -> SessionSelection {
        calls.append(.makeSession)
        connectionStateWhenSessionMade = try? store.connectionState()
        if let makeSessionFailure {
            throw makeSessionFailure
        }
        if !sessionSelections.isEmpty {
            return sessionSelections.removeFirst()
        }
        return SessionSelection(
            backend: backend, me: nil, driver: driver,
            connectionService: sessionConnectionService, audioCalls: sessionAudioCalls,
            now: sessionNow ?? { Date() }
        )
    }

    func runLaunchReport() async -> String {
        calls.append(.runLaunchReport)
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
