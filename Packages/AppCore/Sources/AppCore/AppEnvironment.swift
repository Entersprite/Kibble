import ChatKit
import Foundation
import Observation
import SyncEngine

/// Wires one backend to one store to one window.
///
/// Everything concrete arrives through `LaunchServices`, so this file names no
/// backend, no credential store and no container path. That is what lets a
/// future iOS app link it - and what lets a test drive all nine launch paths
/// with no Keychain, no network and no Google account.
@MainActor
@Observable
public final class AppEnvironment {
    public private(set) var phase: LaunchPhase = .loading

    private let services: any LaunchServices
    private var driver: (any DemoDriver)?

    /// The session this launch built, held from the moment it exists rather
    /// than from the moment it is parked in `.running`.
    ///
    /// **Not derivable from `phase`, and that was a bug rather than a
    /// simplification.** Two production paths build a model, start it, and
    /// then lose the launch to a transition that never parks it:
    ///
    /// - `model.start()` throws. `SyncEngine.start()` assigns its consuming
    ///   `Task` *before* `backend.connect()`, deliberately, so that nothing
    ///   emitted during connection is missed - which means a connect failure
    ///   leaves a live consumer already draining the backend into the store.
    ///   `ChatError.notAuthenticated` is the commonest way that happens (the
    ///   nine-day `COMPASS` fuse, `findings.md` §17.2), and it routes straight
    ///   into `enterNeedsSignIn`.
    /// - `services.startDiagnostics()` throws *after* `phase = .running`. That
    ///   lands on `.failed`, correctly, and takes a fully connected model out
    ///   of reach with it until `requestSignIn()` asks for the way out.
    ///
    /// In both cases `enterNeedsSignIn` used to find no `.running` model and
    /// erase through `LaunchServices.eraseStore()` instead - which opens a
    /// *second* connection to the same file and never stops the session that
    /// is still writing into it. That is precisely the interleaving
    /// `ChatSessionModel.stopAndEraseStore()` exists to make impossible, so
    /// the model has to be reachable before it is parked, not after.
    private var model: ChatSessionModel?

    /// The last value `setActive(_:)` was told, held even while `model` is
    /// `nil` so it is not silently dropped.
    ///
    /// **Why this exists at all.** `start()` races the app shell: the `.task`
    /// that reports frontmost/resigned can fire before `start()` has built a
    /// model - which, for the real backend, means a full HTTP shell fetch
    /// plus channel registration, so this is not a narrow window. Before this
    /// property existed, `setActive(_:)` forwarded straight to `model?.` and
    /// any value that arrived while `model` was `nil` was gone for good,
    /// while `ChatSessionModel.isActive` defaults to `true` - so a resign
    /// during bootstrap, or during the entire web-view login before
    /// `signedIn()` rebuilds the model, left the app backgrounded with the
    /// gate reading `true`. Spec §3.2 chose "only while the app window is
    /// actually frontmost" and explicitly rejected always-publishing; that
    /// drop was the rejected alternative arriving by accident.
    ///
    /// Applied at construction, right beside `beginSettingsSession(engine:)` in
    /// `start()`, which is the one place a model is actually built.
    private var pendingActive: Bool?

    /// The other two inputs to the viewing gate, beside `pendingActive`'s
    /// frontmost. Written from `AppEnvironment+Viewing.swift`; see
    /// `isViewing` there.
    var windowOpen = true
    var windowMinimized = false

    /// Bumped to ask the host to bring the main window forward - a
    /// notification clicked while no window is open. `AppCore` cannot open a
    /// window itself; the host observes this and does.
    public internal(set) var windowRequests = 0

    /// `nil` when the host supplies no way to deliver notifications - every
    /// test that does not care, and any future host without them.
    let notifications: NotificationCoordinator?

    /// Notification rules for whichever account is identified - see
    /// `NotificationSettingsModel` and `AppEnvironment+Settings.swift`.
    public let settings: NotificationSettingsModel
    /// Follows the running model's identity into `settings`.
    var identityTask: Task<Void, Never>?
    /// The running engine's receipts gate, held for tests to read.
    var receiptGate: ReadReceiptGate?

    /// Guards `signOut()` against a second concurrent call: two scenes (the
    /// main window and the Settings window) each carry their own confirmation
    /// dialog, so both can be confirmed before either finishes.
    private var isSigningOut = false

    public init(
        services: any LaunchServices,
        notifications delivery: (any NotificationDelivering)? = nil,
        settingsStore: any NotificationSettingsStore = InMemoryNotificationSettingsStore()
    ) {
        self.services = services
        // Only a real account may take the legacy ghost-mode key; the fixture
        // identifies a demo account of its own.
        settings = NotificationSettingsModel(
            store: settingsStore, migratesLegacyGhostMode: services.arguments.usesRealBackend
        )
        notifications = delivery.map(NotificationCoordinator.init(delivery:))
        notifications?.onShowWindow = { [weak self] in self?.windowRequests += 1 }
        notifications?.resolveRule = { [settings] in settings.resolved(for: $0) }
        notifications?.start()
    }

    public func start() async {
        if case .running = phase {
            return
        }
        if let probe = services.arguments.probe {
            phase = await .report(services.runProbe(probe))
            return
        }
        do {
            // Asked before anything is built, and only for the real bridge: a
            // launch with no stored session is not an error and must not be
            // reported as one - it is a first run, and the only sensible thing
            // to show is a sign-in.
            if services.arguments.usesRealBackend {
                guard try await services.hasStoredSession() else {
                    await enterNeedsSignIn(reason: nil)
                    return
                }
            }
            let store = try services.openStore()
            // Before a backend is even chosen: this is a fresh process, so
            // nothing is typing and nothing is connected, whatever the file on
            // disk last said.
            try store.apply([.clearEphemeralState])
            let selection = try await services.makeSession()
            let engine = SyncEngine(backend: selection.backend, store: store)
            // Receipts are withheld until an account is identified; its saved
            // rules then decide. The old `ghostMode` key migrates into the
            // first account's global rule (`NotificationSettingsModel`).
            beginSettingsSession(engine: engine)
            let model = ChatSessionModel(
                store: store, engine: engine, me: selection.me, markReadTrace: services.markReadTraceSink()
            )
            // Applies whatever the viewing inputs were told while no model
            // existed yet, rather than leaving this model's `isActive`
            // sitting at its own `true` default - see `pendingActive`'s doc
            // comment for the drop this closes. Unconditional now: with
            // nothing told, `isViewing` is `true`, the model's own default.
            model.setActive(isViewing)
            // Held **before** it is started, not after it is parked in
            // `.running`. By the time `start()` can throw, the engine's
            // consumer is already live - see `model`'s own doc comment for why
            // that one line's placement is the whole finding.
            self.model = model
            // Before `start()` for the same reason: arrivals during connect
            // are real arrivals. The stream buffers, so this is ordering
            // hygiene rather than a race.
            notifications?.attach(model, announcements: engine.announcements)
            followIdentity(of: model)

            try await model.start()
            // Only now: a launching "Mark as Read" submitted mid-connect is lost.
            notifications?.replayPending()
            phase = .running(model)
            notifications?.requestAuthorizationOnce()

            if services.arguments.runsDiagnostics {
                try services.startDiagnostics()
            }

            if let driver = selection.driver {
                // The demo world does not move on its own. The driver is what
                // makes a launched app look alive rather than like a screenshot.
                await driver.start()
                self.driver = driver
            }
        } catch ChatError.notAuthenticated {
            // The one error that is not a failure: the credential is there and
            // Google has stopped accepting it. Expiry never proves this and
            // never disproves it (`findings.md` §11), so it is only knowable
            // from a round trip - and this is that round trip having happened.
            //
            // This is the commonest way a *different* account ends up
            // reopening the same database: the nine-day `COMPASS` fuse burns
            // out far more often than anyone clicks Sign Out. Routing it
            // through `enterNeedsSignIn` rather than setting `phase` directly
            // is what makes the erase happen here too, not only on the menu
            // command.
            await enterNeedsSignIn(
                reason: "Your Google session stopped working. Sign in again."
            )
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Called by the login window once a capture has reached the credential
    /// store. Re-runs `start()`, which now finds a session where a moment ago
    /// there was none - so signing in connects rather than printing
    /// "relaunch me".
    ///
    /// **Idempotent against a session that is already up**, and that guard is
    /// not defensive padding: one sign-in can reach here twice.
    /// `CookieCaptureModel.attemptAutoSave` latches `hasAutoSaved`
    /// synchronously, which flips `showsManualControls` to `true` while its own
    /// Keychain write is still in flight - so "Save and continue" is clickable
    /// during the automatic attempt and both routes call `onSaved()`. Setting
    /// `phase = .loading` unconditionally defeated `start()`'s own
    /// `if case .running` guard, and the second call then built a second engine
    /// and a second model over one store, with the first leaked and never
    /// stopped. `CookieCaptureModel` now also latches its completion, so this
    /// is the second of two guards rather than the only one.
    public func signedIn() async {
        if case .running = phase {
            return
        }
        phase = .loading
        await start()
    }

    /// Forgets this account on this Mac.
    ///
    /// **Not a revocation.** The session Google issued stays valid there until
    /// it expires on its own; "sign out" here means only that this Mac stops
    /// remembering it, so the next launch has nothing to reconnect with and
    /// asks for a fresh login.
    ///
    /// Forgetting the credential happens **before** `enterNeedsSignIn` rather
    /// than after: that function is the one and only place the store gets
    /// erased before this Mac may show a login window at all (see its own doc
    /// comment), and a failure inside it must not have already discarded the
    /// credential behind it - that would strand someone with no session and no
    /// way to reach one. If forgetting itself fails, nothing is erased and
    /// nothing changes to `.needsSignIn` - the session is still there to retry
    /// signing out of.
    public func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await services.forgetStoredSession()
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        await enterNeedsSignIn(reason: nil)
    }

    /// The only way `phase` may become `.needsSignIn` - **erasing the store
    /// first is what makes that structural rather than a convention.**
    ///
    /// Erasing used to be tied to the Sign Out menu command alone, but that is
    /// not the likeliest way a different account ends up reopening the same
    /// database: the nine-day `COMPASS` fuse (`findings.md` §17.2) burning out
    /// and `requestSignIn()`'s escape from `.failed` both used to set `phase`
    /// directly and leave whatever was already in the database exactly where it
    /// was. Routing every entry into `.needsSignIn` through this one function -
    /// `start()`'s two paths, `requestSignIn()`, and `signOut()` - is what
    /// makes it impossible to reach the login window without the erase having
    /// already happened, rather than something each call site has to remember.
    ///
    /// **Whenever a session exists at all** it is stopped and its own store
    /// erased through `ChatSessionModel.stopAndEraseStore()`, in that order,
    /// inside one call. The test is `model != nil`, not `phase == .running`:
    /// a model that was built and started but never parked is still a live
    /// consumer writing into the store, and asking `phase` about it answered
    /// "no session" for exactly the two commonest failures - see `model`'s
    /// own doc comment. Erasing around a running consumer through
    /// `LaunchServices` is the interleaving `stopAndEraseStore()` documents
    /// itself as preventing, and it opens a second connection to the same
    /// file as well.
    ///
    /// Only when no model was ever built (a probe, a refused credential
    /// store, an `openStore()` that threw) does the erase go through
    /// `LaunchServices` directly, since there is genuinely no live model to
    /// ask; erasing an already-empty store is a cheap no-op, which is the
    /// point - nothing here has to know whether there is anything to erase.
    private func enterNeedsSignIn(reason: String?) async {
        identityTask?.cancel()
        identityTask = nil
        // Nothing is deleted: the account's settings wait for it to sign in again.
        settings.switchAccount(to: nil)
        do {
            if let model {
                // The fixture's demo world, ticking on its own actor. Its
                // writes reach the store only through `SyncEngine`'s consumer
                // loop, which `stopAndEraseStore()` has already drained by the
                // time this stops it - so this is hygiene, not a second guard
                // against the same race.
                if let driver {
                    await driver.stop()
                    self.driver = nil
                }
                // Before the erase: the next session may be another account,
                // and this one's message text must not stay in Notification
                // Center after the store holding it is gone.
                await notifications?.detach()
                try await model.stopAndEraseStore()
            } else {
                try services.eraseStore()
            }
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        // Released only once the erase actually landed. A `stopAndEraseStore()`
        // that threw has stopped the session but not emptied it, and the retry
        // must go back through that same connection rather than forward to
        // `LaunchServices.eraseStore()` and a second one.
        model = nil
        phase = .needsSignIn(reason: reason)
    }

    /// The way back to sign-in from a launch that failed.
    ///
    /// `.needsSignIn` is otherwise reachable from exactly two inputs - no
    /// stored session, and `ChatError.notAuthenticated`. Everything else lands
    /// in `.failed` and would stay there: a page-shape change
    /// (`findings.md` §18), a client refused as an unsupported browser (where
    /// re-capturing with a different user agent is the actual fix), a stored
    /// session that no longer decodes. Each reproduces on every relaunch, and
    /// the only escape would be deleting a credential by hand - which is not
    /// something this app's intended user can do.
    ///
    /// The reason carried forward is the failure itself, so the capture window
    /// says what went wrong rather than implying the person did something.
    public func requestSignIn() {
        guard case let .failed(message) = phase else { return }
        Task { await enterNeedsSignIn(reason: message) }
    }

    /// Forwarded to the session model, which decides what to do with it.
    /// `AppEnvironment` names no platform API here - see `MacHost`'s
    /// `AppActivityMonitor` for where the macOS signal actually comes from.
    ///
    /// **Stored, not dropped, before a model exists** (`.loading`,
    /// `.needsSignIn`, `.failed`, `.report`). This used to forward straight to
    /// `model?.` and silently discard anything told while `model` was `nil` -
    /// `ChatSessionModel.isActive` defaults to `true`, so a resign during the
    /// real backend's bootstrap (a full HTTP shell fetch plus channel
    /// registration) or during the entire web-view login before `signedIn()`
    /// rebuilds the model left the app backgrounded with the gate reading
    /// `true`, publishing a read receipt for every conversation opened and
    /// message arriving. Spec §3.2 explicitly rejected always-publishing;
    /// that drop was the rejected alternative arriving by accident. Now the
    /// value is kept in `pendingActive` and applied the moment `start()`
    /// builds a model - see that property's doc comment.
    ///
    /// **This is now one of three inputs**, not the model's value itself: the
    /// model is told `isViewing` (`AppEnvironment+Viewing.swift`), so frontmost
    /// with the window closed or minimised is not viewing.
    public func setActive(_ active: Bool) {
        pendingActive = active
        applyViewing()
    }

    /// Whether the user can see the window: frontmost, open and not minimised.
    ///
    /// **One value for two consumers, so they cannot drift.** Automatic
    /// mark-as-read publishes only while this is true, and a notification is
    /// suppressed as "on screen" only while it is true. Before it existed the
    /// model was told frontmost alone, from a `.task` on the window's own view
    /// - so closing the window cancelled the only thing reporting focus, left
    /// the value frozen at `true`, and read receipts could be published for a
    /// conversation nobody could see. Unknown frontmost reads as `true`, the
    /// model's own default, which `pendingActive`'s doc comment explains.
    var isViewing: Bool {
        (pendingActive ?? true) && windowOpen && !windowMinimized
    }

    func applyViewing() {
        model?.setActive(isViewing)
    }

    /// Whether `signOut()` has a running session to act on. The menu command is
    /// disabled otherwise - there is nothing to confirm forgetting.
    public var canSignOut: Bool {
        if case .running = phase {
            return true
        }
        return false
    }
}
