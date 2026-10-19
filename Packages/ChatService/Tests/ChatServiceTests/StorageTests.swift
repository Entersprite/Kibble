import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct StorageTests {
    let account = ConnectedAccountID("test-account")

    @Test func journalResyncAndRestartKeepAStableStream() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("service.sqlite").path
        let first = try SQLiteAccountStorage(account: account, path: path, retention: 2)
        let initial = try first.readEvents(after: nil, limit: 10)
        #expect(initial.snapshot != nil)
        _ = try first.append(.connectionStateChanged(.connecting), live: true)
        let delivered = try first.append(.connectionStateChanged(.connected), live: true)
        let secondClient = try first.readEvents(after: initial.checkpoint, limit: 10)
        #expect(secondClient.events.count == 2)
        #expect(secondClient.checkpoint == delivered)
        #expect(secondClient.events.allSatisfy { !$0.isLiveArrival })
        _ = try first.append(.connectionStateChanged(.idle), live: true)
        let gap = try first.readEvents(after: initial.checkpoint, limit: 10)
        #expect(gap.snapshot != nil)
        #expect(gap.events.isEmpty)
        let reopened = try SQLiteAccountStorage(account: account, path: path)
        let current = try reopened.readEvents(after: nil, limit: 10)
        #expect(current.checkpoint.streamID == delivered.streamID)
        #expect(current.checkpoint.sequence == 3)
    }

    @Test func operationRetryCannotChangePayloadAndCrashCannotRedispatch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("service.sqlite").path
        let first = try SQLiteAccountStorage(account: account, path: path)
        let operationID = ServiceOperationID("one")
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("first"), accountID: account),
            payload: SendCommand(
                operationID: operationID,
                command: .loadMembers(conversationID: Conversation.ID("same"))
            )
        )
        let accepted = try first.reserve(operationID, request: request)
        #expect(accepted.state == "accepted")
        try first.finish(ServiceOperation(id: operationID, state: "dispatching"))
        let retry = ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("second"), accountID: account),
            operation: request.operation,
            payload: request.payload
        )
        #expect(try first.reserve(operationID, request: retry).state == "dispatching")
        let changed = try ServiceRequest(header: retry.header, payload: SendCommand(
            operationID: operationID, command: .loadMembers(conversationID: Conversation.ID("different"))
        ))
        #expect(throws: ServiceFailure.operationConflict) { try first.reserve(operationID, request: changed) }
        let reopened = try SQLiteAccountStorage(account: account, path: path)
        #expect(try reopened.operation(operationID)?.state == "unknown")
    }

    @Test func policyWritesRequireCurrentRevision() throws {
        let store = try SQLiteAccountStorage(account: account, path: ":memory:")
        let first = try store.policy()
        let second = try store.setPolicy(NotificationSettings(), expectedRevision: first.revision)
        #expect(second.revision != first.revision)
        #expect(throws: ServiceFailure.revisionConflict) {
            try store.setPolicy(NotificationSettings(), expectedRevision: first.revision)
        }
    }

    @Test func accountNamespacesDoNotShareEntityIDs() throws {
        let first = try SQLiteAccountStorage(account: account, path: ":memory:")
        let other = try SQLiteAccountStorage(account: ConnectedAccountID("other"), path: ":memory:")
        let conversation = Conversation(id: Conversation.ID("same"), kind: .space, title: "First")
        _ = try first.append(.conversationsChanged([conversation]), live: false)
        #expect(try first.conversations().count == 1)
        #expect(try other.conversations().isEmpty)
        let foreign = try first.readEvents(after: nil, limit: 1).checkpoint
        #expect(try other.readEvents(after: foreign, limit: 1).snapshot != nil)
    }
}
