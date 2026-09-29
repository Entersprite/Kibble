import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// The Mentions list in the running app (the mentions-list spec §4).
@MainActor
struct MentionsListWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    /// 2020, far from any day this suite runs. A wiring that swapped the
    /// session's clock for the wall clock would find this conversation
    /// outside the 30-day window, and fetch nothing.
    private let now = Date(timeIntervalSince1970: 1_600_000_000)

    private var space: Conversation {
        Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design", lastActivity: now)
    }

    private func mention(_ id: String) -> Message {
        Message(
            id: Message.ID(id), conversationID: space.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "@Me hello", createdAt: now.addingTimeInterval(-60),
            mentions: [Mention(target: .user(me.id), start: 0, length: 3)]
        )
    }

    private func running() async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices()
        let clock = now
        services.sessionNow = { clock }
        services.backend.answerHistory(with: [mention("m:1")])
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.membersResolved([alice]))
        services.backend.emit(.conversationsChanged([space]))
        #expect(await eventually { environment.sceneState.mentions.count == 1 })
        return (environment, services)
    }

    /// The whole path. A world load starts the backfill on the session's own
    /// clock, the page is filed, and the row, its badge and the pane read it.
    @Test func aWorldLoadFillsTheRowAndThePaneOnTheSessionsClock() async throws {
        let (environment, _) = try await running()
        #expect(await eventually {
            environment.sceneState.mentions.first?.senderName == "Alice"
                && environment.sceneState.mentionsStatus == MentionsStatus()
        })
        let state = environment.sceneState
        #expect(state.mentions.first?.conversationTitle == "Design")
        #expect(state.mentions.first?.isUnread == true)
        #expect(state.unreadMentionCount == 1)
        #expect(environment.actions.showMentions != nil)
        withExtendedLifetime(environment) {}
    }

    @Test func choosingMentionsThenAnItemOpensItsConversationAtThatMessage() async throws {
        let (environment, _) = try await running()
        environment.actions.showMentions?()
        #expect(environment.sceneState.sidebarSelection == .mentions)
        #expect(environment.sceneState.selected == nil)
        environment.actions.openMention?(space.id, Message.ID("m:1"))
        #expect(environment.sceneState.sidebarSelection == .conversation(space.id))
        #expect(environment.sceneState.scrollTarget == Message.ID("m:1"))
        withExtendedLifetime(environment) {}
    }

    /// Spec §3: rules do not hide mentions. A pin: nothing in the scene
    /// mapping may filter by rule.
    @Test func aMutedConversationsMentionStillShowsAndCounts() async throws {
        let (environment, _) = try await running()
        #expect(await eventually { environment.settings.account == me.id })
        environment.settings.mute(space.id)
        #expect(environment.sceneState.muted == [space.id])
        #expect(environment.sceneState.mentions.count == 1)
        #expect(environment.sceneState.unreadMentionCount == 1)
        withExtendedLifetime(environment) {}
    }

    @Test func noRunningSessionOffersNoMentionsRow() throws {
        let environment = try AppEnvironment(services: FakeLaunchServices())
        #expect(environment.actions.showMentions == nil)
        #expect(environment.actions.openMention == nil)
    }
}
