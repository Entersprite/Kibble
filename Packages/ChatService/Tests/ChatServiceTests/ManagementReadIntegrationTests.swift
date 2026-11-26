import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

extension ReconciliationBackend {
    func setDetailsQuery(_ query: @escaping @Sendable () async throws -> ConversationDetails) {
        detailsQuery = query
    }

    func conversationDetails(_: Conversation.ID) async throws -> ConversationDetails {
        guard let detailsQuery else { throw ChatError.unsupported(capability: "conversationDetails") }
        return try await detailsQuery()
    }
}

private actor DetailsReadGate {
    var value: ConversationDetails
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    var held: Bool {
        waiter != nil
    }

    init(_ value: ConversationDetails) {
        self.value = value
    }

    func read() async -> ConversationDetails {
        reads += 1
        let answer = value
        if reads == 1 {
            await withCheckedContinuation { waiter = $0 }
        }
        return answer
    }

    func replace(_ value: ConversationDetails) {
        self.value = value
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ManagementReadIntegrationTests {
    @Test(arguments: [false, true])
    func infoLoadsDuringTrafficAndRechecksItsOwnChanges(relevant: Bool) async throws {
        let harness = try await ReconciliationHarness.make()
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return try world == nil && backfill == nil
                && harness.storage.conversation(ReconciliationBackend.conversation) != nil
        }
        let id = ReconciliationBackend.conversation
        let before = ConversationDetails(conversation: Conversation(id: id, kind: .space, title: "Before"))
        let gate = DetailsReadGate(before)
        await harness.backend.setDetailsQuery { await gate.read() }
        let query = Task { try await harness.call(GetConversationDetails(conversationID: id)) }
        do {
            try await authEventually { await gate.held }
            let runtime = try #require(await harness.service.runtimes[harness.record.id])
            let after = ConversationDetails(conversation: Conversation(id: id, kind: .space, title: "After"))
            await gate.replace(after)
            // Drive the same invalidation entry point used by committed provider events
            // while the serialized Info request is suspended in provider I/O.
            for index in 0 ..< 12 {
                let row = Conversation(id: relevant ? id : .init("other-\(index)"), kind: .space)
                await runtime.invalidateMediaQueries(for: .conversationUpdated(row))
            }
            await gate.release()
            let value = try await query.value
            #expect(value == (relevant ? after : before))
            #expect(await gate.reads == (relevant ? 2 : 1))
        } catch {
            await gate.release()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }
}
