import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

@MainActor
struct MentionWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let space = Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design")

    /// `ConversationRulesWiringTests.identified`'s shape, narrowed to what
    /// this file's tests need: no test here reads the model or the
    /// capabilities, so the tuple drops both rather than naming a type for
    /// two call sites.
    private func identified(
        _ delivery: FakeNotificationDelivery? = nil
    ) async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case .running = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([space]))
        #expect(await eventually {
            environment.settings.account == me.id && environment.model?.conversations.count == 1
        })
        return (environment, services)
    }

    private func message(_ id: String, mentions: [Mention]) -> Message {
        Message(
            id: Message.ID(id), conversationID: space.id, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "@Me hello",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            mentions: mentions
        )
    }

    /// Mentions only on Spaces: the plain message is suppressed, the mention
    /// of me and the @all both post.
    @Test func mentionsOnlyPostsOnlyMentionsOfMeOrAll() async throws {
        let delivery = FakeNotificationDelivery()
        let (environment, services) = try await identified(delivery)
        environment.settings.update(NotificationRule(notifyAbout: .mentions), for: .section(.spaces))
        services.backend.emit(.messageReceived(message("m:1", mentions: [])))
        services.backend.emit(.messageReceived(message(
            "m:2", mentions: [Mention(target: .user(me.id), start: 0, length: 3)]
        )))
        services.backend.emit(.messageReceived(
            message("m:3", mentions: [Mention(target: .all, start: 0, length: 4)])
        ))
        #expect(await eventually { await delivery.posted.count == 2 })
        #expect(await delivery.posted.map(\.id) == ["m:2", "m:3"])
        withExtendedLifetime(environment) {}
    }

    @Test func theEditorsFallbackIsTheGlobalDeliveryUnlessOff() async throws {
        let (environment, _) = try await identified(FakeNotificationDelivery())
        environment.settings.update(NotificationRule(delivery: .banner), for: .global)
        #expect(environment.conversationRuleState(for: space.id).audibleFallback == .banner)
        environment.settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(environment.conversationRuleState(for: space.id).audibleFallback == .bannerAndSound)
    }
}
