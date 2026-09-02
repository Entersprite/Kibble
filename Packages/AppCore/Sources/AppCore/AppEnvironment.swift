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

    public init(services: any LaunchServices) {
        self.services = services
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
            let model = ChatSessionModel(store: store, engine: engine, me: selection.me)

            try await model.start()
            phase = .running(model)

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
    public func signedIn() async {
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
    /// A `.running` session is stopped and its own store erased through
    /// `ChatSessionModel.stopAndEraseStore()`, in that order, inside one call.
    /// Anything else (no session was ever running, or one already failed)
    /// erases the store through `LaunchServices` directly, since there is no
    /// live model to ask; erasing an already-empty store is a cheap no-op,
    /// which is the point - nothing here has to know whether there is anything
    /// to erase.
    private func enterNeedsSignIn(reason: String?) async {
        do {
            if case let .running(model) = phase {
                // The fixture's demo world, ticking on its own actor. Its
                // writes reach the store only through `SyncEngine`'s consumer
                // loop, which `stopAndEraseStore()` has already drained by the
                // time this stops it - so this is hygiene, not a second guard
                // against the same race.
                if let driver {
                    await driver.stop()
                    self.driver = nil
                }
                try await model.stopAndEraseStore()
            } else {
                try services.eraseStore()
            }
        } catch {
            phase = .failed(String(describing: error))
            return
        }
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

    /// Whether `signOut()` has a running session to act on. The menu command is
    /// disabled otherwise - there is nothing to confirm forgetting.
    public var canSignOut: Bool {
        if case .running = phase {
            return true
        }
        return false
    }
}
