import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationActionModelTests {
    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws -> Bool {
        for _ in 0 ..< 400 {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await condition()
    }

    @Test func unreadWaitsForAnAlreadySubmittedReceiptAndHoldsUntilReopen() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let id = autoMarkReadConversation
        harness.model.setActive(true)
        await harness.backend.holdSubmissions(true)
        harness.model.select(id)
        #expect(try await eventually { await harness.backend.markReadCount == 1 })
        harness.model.perform(.markUnread, in: id)
        #expect(await !((harness.backend.commands).contains(.conversationAction(
            conversationID: id,
            action: .markUnread
        ))))
        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        #expect(try await eventually {
            let conversation = try harness.store.conversations().first { $0.id == id }
            return harness.model.conversationActionTasks[id] == nil && conversation?.markedUnreadAt != nil
        })
        let count = await harness.backend.markReadCount
        harness.model.markSelectedReadIfNeeded()
        await settleAutoMarkRead()
        #expect(await harness.backend.markReadCount == count)
        harness.model.clearSelection()
        harness.model.select(id)
        #expect(try await eventually { await harness.backend.markReadCount > count })
        #expect(try await eventually {
            try (harness.store.conversations().first { $0.id == id })?.markedUnreadAt == nil
        })
        await harness.model.stop()
    }

    @Test func hidingTheSelectedConversationClosesItAndKeepsItsMessages() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let id = autoMarkReadConversation
        harness.model.select(id)
        #expect(try await eventually { !harness.model.messages.isEmpty })
        let count = try harness.store.messages(in: id).count
        harness.model.perform(.hide, in: id)
        #expect(try await eventually {
            harness.model.selected == nil && harness.model.conversationActionTasks[id] == nil
        })
        #expect(try harness.store.messages(in: id).count == count)
        #expect(try harness.store.conversations().allSatisfy { $0.id != id })
        await harness.model.stop()
    }

    @Test func failedActionKeepsTheConversationAndHistory() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let id = autoMarkReadConversation
        await harness.backend.failSubmissions(true)
        harness.model.perform(.delete, in: id)
        #expect(try await eventually { harness.model.conversationActionTasks[id] == nil })
        #expect(try harness.store.conversations().contains { $0.id == id })
        #expect(await harness.backend.commands.contains(.conversationAction(
            conversationID: id,
            action: .delete
        )))
        await harness.model.stop()
    }
}

extension ConversationActionModelTests {
    @Test func aFailedUnreadActionRemainsReadableAfterUnrelatedTraffic() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let id = autoMarkReadConversation
        await harness.backend.failSubmissions(true)
        harness.model.perform(.markUnread, in: id)
        #expect(try await eventually { harness.model.lastError != nil })
        let failure = harness.model.lastError
        try harness.store.apply([.setLastError(nil), .upsertMembers(FixtureWorld.minimal.members)])
        await settleAutoMarkRead()
        #expect(harness.model.lastError == failure)
        #expect(harness.model.conversationActionError == failure)
        await harness.backend.failSubmissions(false)
        harness.model.perform(.markUnread, in: id)
        #expect(try await eventually { harness.model.conversationActionTasks[id] == nil })
        #expect(harness.model.conversationActionError == nil)
        await harness.model.stop()
    }
}
