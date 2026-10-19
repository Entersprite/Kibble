import ChatAPI
import ChatKit
import ChatService
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HintAdmissionTests {
    @Test func repeatedCurrentInterestsNeverAccumulateDurableOperations() async throws {
        let reservations = OperationReservationCounter()
        let harness = try await ReconciliationHarness.make(reservations: reservations)
        _ = try await harness.call(LoadConversations())
        let read = SendCommand(operationID: ServiceOperationID("read"), command: .markRead(
            conversationID: ReconciliationBackend.conversation, upTo: ReconciliationBackend.date
        ))
        _ = try await harness.call(read)
        #expect(reservations.count == 1)
        let hints: [ChatCommand] = [
            .reportActivity(active: true), .watchPresence(members: [Member.ID("peer")]),
            .watchConversationActivity(conversationID: ReconciliationBackend.conversation),
            .loadMembers(conversationID: ReconciliationBackend.conversation),
            .setTyping(conversationID: ReconciliationBackend.conversation, threadID: nil, isTyping: false)
        ]
        for _ in 0 ..< 20 {
            for hint in hints {
                try await harness.hint(hint)
            }
        }
        #expect(reservations.count == 1)
        let memberCalls = await harness.backend.sentCommands.filter {
            if case .loadMembers = $0 {
                return true
            }; return false
        }
        #expect(memberCalls.count == 20)
        try await authEventually { await harness.backend.receivePresence == [Member.ID("peer")] }
        await harness.service.shutdown()
    }

    @Test func mutationCannotUseHintAdmissionAndHintsCannotUseTheDurableLedger() async throws {
        let reservations = OperationReservationCounter()
        let harness = try await ReconciliationHarness.make(reservations: reservations)
        _ = try await harness.call(LoadConversations())
        let mutation = ChatCommand.sendMessage(
            conversationID: ReconciliationBackend.conversation, threadID: nil, text: "No bypass", localID: nil
        )
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await harness.hint(mutation)
        }
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await harness.call(SendCommand(
                operationID: ServiceOperationID("hint"), command: .reportActivity(active: true)
            ))
        }
        #expect(await harness.backend.sentCommands.isEmpty)
        let reservationCount = reservations.count
        #expect(reservationCount == 0)
        await harness.service.shutdown()
    }
}

final class OperationReservationCounter: Sendable {
    private let calls = Mutex(0)
    var count: Int {
        calls.withLock { $0 }
    }

    func reserve() {
        calls.withLock { $0 += 1 }
    }
}

struct CountedStorageFactory: ServiceStorageFactory {
    let backing: any ServiceStorageFactory
    let reservations: OperationReservationCounter
    func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
        try CountedAccountStorage(backing: backing.open(account), reservations: reservations)
    }

    func erase(_ account: ConnectedAccountID) throws {
        try backing.erase(account)
    }
}

private struct CountedAccountStorage: ServiceAccountStorage {
    let backing: any ServiceAccountStorage
    let reservations: OperationReservationCounter
    func append(
        _ event: ChatEvent,
        live: Bool
    ) throws -> ServiceCursor {
        try backing.append(event, live: live)
    }

    func readEvents(after cursor: ServiceCursor?, limit: Int) throws -> ServiceEventPage {
        try backing.readEvents(after: cursor, limit: limit)
    }

    func conversations() throws -> [Conversation] {
        try backing.conversations()
    }

    func conversation(_ id: Conversation.ID) throws -> Conversation? {
        try backing.conversation(id)
    }

    func checkpoint() throws -> ServiceCursor {
        try backing.checkpoint()
    }

    func recentHistory(in conversation: Conversation.ID, limit: Int) throws -> [Message] {
        try backing.recentHistory(in: conversation, limit: limit)
    }

    func operation(_ id: ServiceOperationID) throws -> ServiceOperation? {
        try backing.operation(id)
    }

    func reserve(_ id: ServiceOperationID, request: ServiceRequest) throws -> ServiceOperation {
        reservations.reserve()
        return try backing.reserve(id, request: request)
    }

    func finish(_ operation: ServiceOperation) throws {
        try backing.finish(operation)
    }
}
