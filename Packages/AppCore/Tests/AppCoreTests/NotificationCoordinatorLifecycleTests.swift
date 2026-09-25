import ChatKit
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// The coordinator across a session's life: a click that arrives before the
/// session can act on it, and the end of a session with work still in flight.
@MainActor
struct NotificationCoordinatorLifecycleTests {
    private let dm = Conversation.ID("dm/1")
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")

    /// The click that launched the app is replayed once the session has
    /// connected, not the moment it is attached: a "Mark as Read" submitted
    /// while `connect()` is still running is lost. `.open` takes the same
    /// replay path and is observable without the mark's two-second wait.
    @Test func aLaunchingClickIsReplayedOnlyOnceTheSessionHasConnected() async throws {
        let services = try FakeLaunchServices()
        services.backend.holdConnect()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.open(dm))
        // No session yet: the click asks for the window once, and waits.
        #expect(await eventually { environment.windowRequests == 1 })

        let starting = Task { await environment.start() }
        #expect(await eventually { services.backend.connectEntered })
        // Attached and still connecting: nothing replayed yet.
        #expect(environment.windowRequests == 1)

        services.backend.releaseConnect()
        await starting.value
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(model.selected == dm)
        #expect(environment.windowRequests == 2)
    }

    /// A launching click whose session never started is dropped when that
    /// session ends: the next sign-in may be a different account.
    @Test func aClickPendingWhenTheSessionEndsIsNotReplayedIntoTheNext() async throws {
        let services = try FakeLaunchServices()
        services.backend.connectFailure = ChatError.notAuthenticated
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.open(dm))
        #expect(await eventually { environment.windowRequests == 1 })

        // Attached, then detached when the refused session is torn down.
        await environment.start()
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn to set the test up")
            return
        }

        services.backend.connectFailure = nil
        await environment.signedIn()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running once the session connects")
            return
        }
        #expect(model.selected == nil)
        #expect(environment.windowRequests == 1)
    }

    /// A click that arrives once the session has ended - a banner that raced
    /// the withdraw - still brings the window forward, and is not held for
    /// the next sign-in, which may be another account.
    @Test func aClickAfterTheSessionEndedIsNotReplayedIntoTheNext() async throws {
        let services = try FakeLaunchServices()
        services.backend.connectFailure = ChatError.notAuthenticated
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn to set the test up")
            return
        }

        delivery.respond.yield(.open(dm))
        #expect(await eventually { environment.windowRequests == 1 })

        services.backend.connectFailure = nil
        await environment.signedIn()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running once the session connects")
            return
        }
        #expect(model.selected == nil)
        #expect(environment.windowRequests == 1)
    }

    /// The same, inside `detach()` itself: a click while Notification Center
    /// is being cleared lands after `pending` was dropped, so only the latch
    /// being cleared before the first suspension keeps it out of the next
    /// session.
    @Test func aClickWhileSigningOutWithdrawsIsNotReplayedIntoTheNext() async throws {
        let services = try FakeLaunchServices()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }

        await delivery.holdWithdrawAll()
        let signingOut = Task { await environment.signOut() }
        #expect(await eventually { await delivery.withdrawAllsStarted == 1 })
        delivery.respond.yield(.open(dm))
        #expect(await eventually { environment.windowRequests == 1 })
        await delivery.releaseWithdrawAll()
        await signingOut.value
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn once signed out")
            return
        }

        await environment.signedIn()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running once signed back in")
            return
        }
        #expect(model.selected == nil)
    }

    /// No stored session at launch builds no model, and that path ends the
    /// previous process's session too: its banners are withdrawn, and the
    /// click that launched the app is not replayed into whoever signs in.
    @Test func aLaunchWithNoStoredSessionWithdrawsAndDropsTheLaunchingClick() async throws {
        let services = try FakeLaunchServices()
        services.storedSessionExists = false
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.open(dm))
        #expect(await eventually { environment.windowRequests == 1 })

        await environment.start()
        guard case .needsSignIn = environment.phase else {
            Issue.record("expected .needsSignIn to set the test up")
            return
        }
        #expect(await delivery.withdrawAllCount == 1)

        services.storedSessionExists = true
        await environment.signedIn()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running once a credential exists")
            return
        }
        #expect(model.selected == nil)
    }

    /// A post already in flight when the session ends lands before the
    /// withdraw, not after it - or the previous account's message text stays
    /// in Notification Center.
    @Test func signingOutWaitsForAPostInFlightBeforeWithdrawingEverything() async throws {
        let services = try FakeLaunchServices()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { model.me == me.id })

        await delivery.holdPosts()
        services.backend.emit(.messageReceived(Message(
            id: Message.ID("m:1"), conversationID: dm, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "hello",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )))
        #expect(await eventually { await delivery.postsStarted == 1 })

        let signingOut = Task { await environment.signOut() }
        // Room for a withdraw that does not wait to land first. Expected to
        // time out: with the wait in place, nothing is withdrawn yet.
        _ = await eventually(timeout: .milliseconds(200)) { await delivery.withdrawAllCount == 1 }
        await delivery.releasePosts()
        await signingOut.value
        #expect(await delivery.landed == [.posted("m:1"), .withdrewAll])
    }
}
