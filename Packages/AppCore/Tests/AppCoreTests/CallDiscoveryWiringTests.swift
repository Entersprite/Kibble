import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

extension FakeLaunchBackend: CallDiscoveryBackend {
    func callAvailability(in id: Conversation.ID) async throws -> ConversationCallAvailability {
        guard capabilities.canDiscoverCalls else { throw ChatError.unsupported(capability: "callDiscovery") }
        return try callDiscovery.withLock { state in
            state.asked.append(id)
            guard let answer = state.answers[id] else { throw ChatError.transport("no answer") }
            return answer
        }
    }
}

/// The header's call offer in the running app: discovery asks only about the
/// conversation on screen, and only its fresh answer turns Call into Join.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallDiscoveryWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private var space: Conversation {
        Conversation(
            id: Conversation.ID("space/s"),
            kind: .space,
            title: "Design",
            members: [me.id, alice.id]
        )
    }

    private var other: Conversation {
        Conversation(id: Conversation.ID("space/o"), kind: .space, title: "Other", members: [me.id, alice.id])
    }

    private struct Running {
        let environment: AppEnvironment
        let services: FakeLaunchServices
        let calls: ConversationRecordingService
    }

    private func running(discovery: Bool = true) async throws -> Running {
        let services = try FakeLaunchServices(backendCapabilities: Capabilities(
            canSendMessages: true, extendedFlags: discovery ? ["callDiscovery"] : []
        ))
        let calls = ConversationRecordingService(
            recipient: AudioCallRecipient(
                conversationID: Conversation.ID("dm/a"), memberID: alice.id, displayName: "Alice"
            ),
            conversations: true, join: true
        )
        services.sessionAudioCalls = calls
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.membersResolved([alice]))
        services.backend.emit(.conversationsChanged([space, other]))
        #expect(await eventually { environment.sceneState.conversations.count == 2 })
        #expect(await eventually { environment.calls.supportsConversationCalls })
        return Running(environment: environment, services: services, calls: calls)
    }

    private func active(_ id: Conversation.ID) -> ConversationCallAvailability {
        ConversationCallAvailability(
            conversationID: id, status: .active, checkedAt: .distantPast, totalParticipants: 2
        )
    }

    @Test func aCallGoingOnInTheConversationOnScreenOffersJoin() async throws {
        let run = try await running()
        let (environment, services, calls) = (run.environment, run.services, run.calls)
        services.backend.callDiscovery.withLock { $0.answers[space.id] = active(space.id) }
        #expect(environment.sceneState.callOffer == nil)
        environment.actions.select(space.id)
        #expect(await eventually { environment.sceneState.callOffer == .join(participants: 2) })
        #expect(services.backend.callDiscovery.withLock(\.asked) == [space.id])
        // Joining makes it this session's own call, and the header says so.
        environment.actions.joinCall?(space.id)
        #expect(await eventually { calls.operations == ["joinConversation"] })
        #expect(environment.sceneState.callOffer == .returnToCall)
        let requests = environment.calls.windowRequests
        environment.actions.returnToCall?()
        #expect(environment.calls.windowRequests == requests + 1)
        withExtendedLifetime(environment) {}
    }

    @Test func noAnswerMeansCallAndOtherConversationsAreNeverAsked() async throws {
        let run = try await running()
        let (environment, services) = (run.environment, run.services)
        environment.actions.select(other.id)
        #expect(await eventually { services.backend.callDiscovery.withLock(\.asked) == [other.id] })
        #expect(environment.sceneState.callOffer == .call)
        #expect(!services.backend.callDiscovery.withLock(\.asked).contains(space.id))
        withExtendedLifetime(environment) {}
    }

    @Test func aBackendWithoutDiscoveryIsNeverAskedAndOffersCall() async throws {
        let run = try await running(discovery: false)
        let (environment, services) = (run.environment, run.services)
        environment.actions.select(space.id)
        #expect(await eventually { environment.sceneState.callOffer == .call })
        try await Task.sleep(for: .milliseconds(50))
        #expect(services.backend.callDiscovery.withLock(\.asked).isEmpty)
        withExtendedLifetime(environment) {}
    }

    @Test func aClosedWindowStopsAskingUntilItIsSeenAgain() async throws {
        let run = try await running()
        let (environment, services) = (run.environment, run.services)
        services.backend.callDiscovery.withLock { $0.answers[space.id] = active(space.id) }
        environment.setWindowOpen(false)
        environment.actions.select(space.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(services.backend.callDiscovery.withLock(\.asked).isEmpty)
        environment.setWindowOpen(true)
        #expect(await eventually { environment.sceneState.callOffer == .join(participants: 2) })
        withExtendedLifetime(environment) {}
    }
}
