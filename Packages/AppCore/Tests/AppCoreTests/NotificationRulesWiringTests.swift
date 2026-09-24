import ChatKit
import Foundation
import SyncEngine
import Testing
@testable import AppCore

@MainActor
struct NotificationRulesWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let dm = Conversation(id: Conversation.ID("dm/1"), kind: .directMessage, hasUnread: true)
    private let meet = Conversation(
        id: Conversation.ID("space/m"),
        kind: .meetChat,
        title: "Standup",
        hasUnread: true
    )
    private let space = Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ id: String, in conversation: Conversation) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "hello", createdAt: at
        )
    }

    private func running(
        store: InMemoryNotificationSettingsStore = InMemoryNotificationSettingsStore(),
        delivery: FakeNotificationDelivery? = nil
        // A fourth call site (`_`, `services`, `model`) makes a named type
        // worse than the tuple it would replace.
        // swiftlint:disable:next large_tuple
    ) async throws -> (AppEnvironment, FakeLaunchServices, ChatSessionModel) {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services, notifications: delivery, settingsStore: store)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            throw TestSetupFailure()
        }
        return (environment, services, model)
    }

    @Test func receiptsAreWithheldUntilTheAccountIsIdentified() async throws {
        let (environment, services, _) = try await running()
        #expect(environment.receiptGate?.policy == .withhold)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        #expect(environment.receiptGate?.policy == .resolve(environment.settings.settings))
    }

    @Test func theIdentifiedAccountsSavedRulesApply() async throws {
        var saved = NotificationSettings()
        saved.setRule(NotificationRule(readReceipts: false), for: .global, at: at, by: "mac")
        let (
            environment,
            services,
            _
        ) = try await running(store: InMemoryNotificationSettingsStore([me.id: saved]))
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        #expect(environment.settings.rule(for: .global).readReceipts == false)
    }

    @Test func theBadgeAndTheUnreadIndicatorFollowTheRules() async throws {
        let (environment, services, model) = try await running()
        services.backend.emit(.conversationsChanged([dm, meet, space]))
        #expect(await eventually { model.conversations.count == 3 })
        // The Meet preset excludes the Meet chat from both.
        #expect(environment.badgeCount == 1)
        #expect(environment.sceneState.unreadHidden == [meet.id])
    }

    @Test func deliveryPreviewAndPassiveComeFromTheRule() async throws {
        var saved = NotificationSettings()
        saved.setRule(NotificationRule(delivery: .off), for: .section(.directMessages), at: at, by: "mac")
        saved.setRule(
            NotificationRule(delivery: .notificationCenter, showsPreview: false),
            for: .section(.spaces), at: at, by: "mac"
        )
        let delivery = FakeNotificationDelivery()
        let (environment, services, model) = try await running(
            store: InMemoryNotificationSettingsStore([me.id: saved]), delivery: delivery
        )
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([dm, space]))
        #expect(await eventually { model.me == me.id && model.conversations.count == 2 })
        #expect(await eventually { environment.settings.account == me.id })

        services.backend.emit(.messageReceived(message("m:dm", in: dm)))
        services.backend.emit(.messageReceived(message("m:space", in: space)))
        #expect(await eventually { await delivery.posted.count == 1 })
        let posted = await delivery.posted.first
        #expect(posted?.id == "m:space")
        #expect(posted?.isPassive == true)
        #expect(posted?.playsSound == false)
        #expect(posted?.body == "New message")
    }

    /// Review Focus 3.
    ///
    /// **`environment` must be kept alive for the whole test.**
    /// `NotificationCoordinator.start()`/`attach(_:announcements:)` capture
    /// `self` weakly - the coordinator is owned by `AppEnvironment` and must
    /// not outlive it (a stored `Task` with a strong self-capture on a
    /// never-finishing stream would leak the coordinator, and with it the
    /// attached model chain, past `AppEnvironment` going out of scope). So
    /// nothing else keeps this session's coordinator alive; letting
    /// `environment` be discarded here would deallocate it before the
    /// message below is announced, and the notification would silently not
    /// post. `withExtendedLifetime` is the guaranteed way to hold it past
    /// the optimiser reordering an unused binding's release earlier.
    @Test func aMessageForAnUnlistedConversationStillNotifies() async throws {
        let delivery = FakeNotificationDelivery()
        let (environment, services, model) = try await running(delivery: delivery)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { model.me == me.id })
        let unlisted = Conversation(id: Conversation.ID("space/new"), kind: .space)
        services.backend.emit(.messageReceived(message("m:new", in: unlisted)))
        #expect(await eventually { await delivery.posted.count == 1 })
        // `withExtendedLifetime`, not just holding `environment` unused: the
        // stdlib overload of `withExtendedLifetime` taking an async body does
        // not exist, so this is the guaranteed way to keep `environment` (and
        // therefore its weakly-self-capturing `NotificationCoordinator`)
        // retained across every `await` above, rather than trusting the
        // optimiser not to release an otherwise-unused binding early.
        withExtendedLifetime(environment) {}
    }

    @Test func thePaneIsUnavailableUntilIdentifiedAndShowsTheMeetPreset() async throws {
        let (environment, services, _) = try await running()
        #expect(!environment.notificationSettingsState.isAvailable)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.notificationSettingsState.isAvailable })
        #expect(environment.notificationSettingsState.sectionResolved[.meetChats]?.delivery == .off)
    }

    @Test func aSectionEditFromThePaneIsSaved() async throws {
        let store = InMemoryNotificationSettingsStore()
        let (environment, services, _) = try await running(store: store)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        environment.notificationSettingsActions(openSystemSettings: nil)
            .updateSection(.spaces, NotificationRule(delivery: .banner))
        #expect(store.saved(for: me.id)?.rule(for: .section(.spaces))?.delivery == .banner)
    }

    @Test func signingOutKeepsTheAccountsSettings() async throws {
        let store = InMemoryNotificationSettingsStore()
        let (environment, services, _) = try await running(store: store)
        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { environment.settings.account == me.id })
        environment.settings.update(NotificationRule(delivery: .off), for: .global)
        await environment.signOut()
        #expect(environment.settings.account == nil)
        #expect(store.saved(for: me.id)?.rule(for: .global)?.delivery == .off)
    }
}

struct TestSetupFailure: Error {}
