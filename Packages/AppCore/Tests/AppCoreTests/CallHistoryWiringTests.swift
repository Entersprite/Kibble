import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

extension FakeLaunchBackend: CallHistoryBackend {
    func callHistory(_ query: CallHistoryQuery) async throws -> CallHistoryPage {
        guard capabilities.canReadCallHistory else { throw ChatError.unsupported(capability: "callHistory") }
        return callHistoryPages.withLock { state in
            state.queries.append(query)
            return state.page
        }
    }
}

/// The Calls list in the running app: the row is offered only by a backend
/// that keeps call records, and the pane, its rows and opening one read the
/// session model through the scene.
@MainActor
struct CallHistoryWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let now = Date(timeIntervalSince1970: 1_600_000_000)

    private var space: Conversation {
        Conversation(id: Conversation.ID("space/s"), kind: .space, title: "Design", lastActivity: now)
    }

    private func record(_ id: String, from sender: Member.ID, status: MessageCallStatus) -> Message {
        Message(
            id: Message.ID(id), conversationID: space.id, threadID: MessageThread.ID("t-" + id),
            sender: sender, text: "", createdAt: now.addingTimeInterval(-60), callStatus: status
        )
    }

    private func running(history: Bool = true) async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices(backendCapabilities: Capabilities(
            canSendMessages: true, extendedFlags: history ? ["callHistory"] : []
        ))
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.membersResolved([alice]))
        services.backend.emit(.conversationsChanged([space]))
        #expect(await eventually { environment.sceneState.conversations.count == 1 })
        return (environment, services)
    }

    @Test func choosingCallsListsTheRecordsBesideTheirConversations() async throws {
        let (environment, services) = try await running()
        services.backend.callHistoryPages.withLock {
            $0.page = CallHistoryPage(messages: [
                record("c:2", from: alice.id, status: .missed), record("c:1", from: me.id, status: .ended)
            ])
        }
        let actions = try #require(environment.actions.callHistory)
        actions.show()
        #expect(environment.sceneState.sidebarSelection == .calls)
        #expect(environment.sceneState.selected == nil)
        #expect(await eventually { environment.sceneState.callHistory.status == .loaded })
        let items = environment.sceneState.callHistory.items
        #expect(items.map(\.conversationTitle) == ["Design", "Design"])
        #expect(items.map(\.senderName) == ["Alice", "You"])
        #expect(items.map(\.status) == [.missed, .ended])
        #expect(items.first?.conversation?.id == space.id)
        withExtendedLifetime(environment) {}
    }

    @Test func openingARecordGoesToItsMessageInItsConversation() async throws {
        let (environment, services) = try await running()
        services.backend.callHistoryPages.withLock {
            $0.page = CallHistoryPage(messages: [record("c:1", from: alice.id, status: .ended)])
        }
        let actions = try #require(environment.actions.callHistory)
        actions.show()
        #expect(await eventually { environment.sceneState.callHistory.status == .loaded })
        actions.open(space.id, Message.ID("c:1"))
        #expect(environment.sceneState.sidebarSelection == .conversation(space.id))
        #expect(environment.sceneState.scrollTarget == Message.ID("c:1"))
        #expect(!environment.sceneState.callHistory.showingList)
        withExtendedLifetime(environment) {}
    }

    @Test func aBackendWithoutCallHistoryOffersNoCallsRow() async throws {
        let (environment, _) = try await running(history: false)
        #expect(environment.actions.callHistory == nil)
        #expect(environment.sceneState.callHistory == CallHistoryScene())
        withExtendedLifetime(environment) {}
    }

    @Test func noRunningSessionOffersNoCallsRow() throws {
        let environment = try AppEnvironment(services: FakeLaunchServices())
        #expect(environment.actions.callHistory == nil)
    }
}
