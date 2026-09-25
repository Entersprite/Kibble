import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

@MainActor
struct ConversationRulesWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let dm = Conversation(
        id: Conversation.ID("dm/1"), kind: .directMessage, hasUnread: true,
        members: [Member.ID("users/me"), Member.ID("users/alice")]
    )
    private let meet = Conversation(
        id: Conversation.ID("space/m"), kind: .meetChat, title: "Standup", hasUnread: true
    )
    private let space = Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private let marking = Capabilities(canSendMessages: true, canMarkRead: true)

    private func identified(
        delivery: FakeNotificationDelivery? = nil,
        capabilities: Capabilities? = nil
        // `NotificationRulesWiringTests.running`'s shape, for its reason: a
        // named type would be worse than the tuple it replaced.
        // swiftlint:disable:next large_tuple
    ) async throws -> (AppEnvironment, FakeLaunchServices, ChatSessionModel) {
        let services = try FakeLaunchServices(backendCapabilities: capabilities)
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([dm, meet, space]))
        #expect(await eventually {
            environment.settings.account == me.id && model.conversations.count == 3
        })
        return (environment, services, model)
    }

    private func message(_ id: String, in conversation: Conversation) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "hello", createdAt: at
        )
    }

    @Test func mutingFromTheSidebarDimsHidesAndUncountsAndUnmuteUndoesIt() async throws {
        let (environment, _, _) = try await identified()
        #expect(environment.badgeCount == 1)
        environment.actions.mute?(dm.id)
        #expect(environment.sceneState.muted == [dm.id])
        #expect(environment.sceneState.dimmed.contains(dm.id))
        #expect(environment.sceneState.unreadHidden.contains(dm.id))
        #expect(environment.badgeCount == 0)
        environment.actions.unmute?(dm.id)
        #expect(environment.sceneState.muted.isEmpty)
        #expect(!environment.sceneState.dimmed.contains(dm.id))
        #expect(environment.badgeCount == 1)
    }

    /// Review Focus 2, as the sidebar sees it.
    @Test func aMeetChatIsDimmedButOnlyMutedByItsOwnRecord() async throws {
        let (environment, _, _) = try await identified()
        #expect(environment.sceneState.dimmed.contains(meet.id))
        #expect(!environment.sceneState.muted.contains(meet.id))
        environment.actions.mute?(meet.id)
        #expect(environment.sceneState.muted.contains(meet.id))
        environment.actions.unmute?(meet.id)
        #expect(!environment.sceneState.muted.contains(meet.id))
        #expect(environment.sceneState.dimmed.contains(meet.id))
    }

    @Test func noMuteIsOfferedBeforeTheAccountIsKnown() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        #expect(environment.actions.mute == nil)
        #expect(!environment.canEditNotificationRules)
    }

    /// The other half of `canEditNotificationRules`: an account identified
    /// during connect is not yet a running session.
    @Test func noMuteIsOfferedWhileTheSessionIsStillConnecting() async throws {
        let services = try FakeLaunchServices()
        services.backend.holdConnect()
        let environment = AppEnvironment(services: services)
        let starting = Task { await environment.start() }
        #expect(await eventually { services.backend.connectEntered })
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        #expect(!environment.canEditNotificationRules)
        #expect(environment.actions.mute == nil)
        services.backend.releaseConnect()
        await starting.value
        // The control: the same environment offers it once running.
        #expect(environment.canEditNotificationRules)
    }

    @Test func theEditorShowsWhatTheConversationInherits() async throws {
        let (environment, _, _) = try await identified()
        environment.settings.update(NotificationRule(delivery: .banner), for: .section(.spaces))
        environment.settings.update(NotificationRule(delivery: .off), for: .conversation(space.id))
        let state = environment.conversationRuleState(for: space.id)
        #expect(state.title == "Design")
        #expect(state.inherited.delivery == .banner)
        #expect(state.resolved.delivery == .off)
    }

    /// Review Focus 5.
    @Test func anUnlistedConversationWithARecordIsStillInThePaneAndResets() async throws {
        let (environment, _, _) = try await identified()
        let gone = Conversation.ID("space/gone")
        environment.settings.update(NotificationRule(showsPreview: false), for: .conversation(gone))
        environment.settings.mute(dm.id)
        // Record order: the pane lists overrides in the order they were made.
        let rows = environment.notificationSettingsState.conversations
        #expect(rows.map(\.id) == [gone, dm.id])
        #expect(rows.first?.title == "Unavailable conversation")
        environment.notificationSettingsActions(openSystemSettings: nil)
            .updateConversation(gone, NotificationRule())
        #expect(environment.notificationSettingsState.conversations.map(\.id) == [dm.id])
    }

    @Test func pausingShowsAStatusAndSilencesArrivalsUntilResumed() async throws {
        let delivery = FakeNotificationDelivery()
        let (environment, services, _) = try await identified(delivery: delivery)
        environment.pauseNotifications(.untilResumed)
        #expect(environment.pauseStatus == "Paused until you resume")
        #expect(environment.notificationSettingsState.pauseStatus == "Paused until you resume")
        services.backend.emit(.messageReceived(message("m:1", in: dm)))
        // A barrier: the coordinator takes announcements one at a time, in
        // order, and a withdrawal lands whatever the pause says - so once it
        // has, m:1 was decided while still paused. Resuming straight after the
        // emit let m:1 be decided after the resume, and it posted.
        services.backend.emit(.readStateChanged(conversationID: dm.id, lastReadAt: at, unread: 0))
        #expect(await eventually { await delivery.withdrawals.count == 1 })
        environment.resumeNotifications()
        #expect(environment.pauseStatus == nil)
        services.backend.emit(.messageReceived(message("m:2", in: space)))
        // The control: m:2 posts, so m:1's absence is the pause, not a stall.
        #expect(await eventually { await delivery.posted.count == 1 })
        #expect(await delivery.posted.map(\.id) == ["m:2"])
        withExtendedLifetime(environment) {}
    }

    @Test func thePanesPauseAndResumeReachTheSettings() async throws {
        let (environment, _, _) = try await identified()
        let actions = environment.notificationSettingsActions(openSystemSettings: nil)
        actions.pause(.untilResumed)
        #expect(environment.settings.isPaused)
        actions.resume()
        #expect(!environment.settings.isPaused)
    }

    @Test func aBannersMuteButtonMutesItsConversation() async throws {
        let delivery = FakeNotificationDelivery()
        let (environment, _, _) = try await identified(delivery: delivery)
        delivery.respond.yield(.mute(dm.id))
        #expect(await eventually { environment.settings.isMuted(dm.id) })
    }

    @Test func markAsReadIsOfferedOnlyWithAnAccountAndABackendThatMarks() async throws {
        let (plain, _, _) = try await identified()
        #expect(plain.actions.markRead == nil)
        // The account half: a running session whose backend marks, and nobody
        // identified yet.
        let unidentified = try AppEnvironment(services: FakeLaunchServices(backendCapabilities: marking))
        await unidentified.start()
        #expect(unidentified.runningModel?.capabilities.canMarkRead == true)
        #expect(unidentified.actions.markRead == nil)
        let (environment, _, _) = try await identified(capabilities: marking)
        #expect(environment.actions.markRead != nil)
        environment.settings.update(NotificationRule(readReceipts: false), for: .section(.spaces))
        #expect(environment.sceneState.receiptsWithheld == [space.id])
    }

    /// Two seconds, because the environment builds its model with the real
    /// `markReadDebounce` - the only way to see the item reach the backend.
    @Test func markAsReadFromTheSidebarPublishes() async throws {
        let (environment, services, _) = try await identified(capabilities: marking)
        // Not viewing, so selecting cannot publish: with the window in view,
        // an item wired to `select` published the same mark automatically and
        // this test could not tell the two apart. The explicit mark ignores focus.
        environment.setActive(false)
        services.backend.emit(.messageReceived(message("m:1", in: dm)))
        // Stored well inside the mark's two-second wait.
        environment.actions.markRead?(dm.id)
        #expect(await eventually(timeout: .seconds(4)) {
            services.backend.sent.contains(.markRead(conversationID: dm.id, upTo: at))
        })
    }

    /// Decision 4: a Mute that launched the app waits for the session, and so
    /// for the account, like every other held click.
    @Test func aMuteThatLaunchedTheAppLandsOnceTheAccountIsKnown() async throws {
        let services = try FakeLaunchServices()
        services.backend.holdConnect()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.mute(dm.id))
        let starting = Task { await environment.start() }
        #expect(await eventually { services.backend.connectEntered })
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        #expect(!environment.settings.isMuted(dm.id))
        services.backend.releaseConnect()
        await starting.value
        #expect(await eventually { environment.settings.isMuted(dm.id) })
    }
}
