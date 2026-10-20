import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RetentionTests {
    private let account = ConnectedAccountID("account")

    @Test func prunedOperationIDsCannotExecuteAgainAfterRestartOrClockRollback() throws {
        let clock = RetentionClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("service.sqlite").path
        let limits = AccountRetentionLimits(maximumAge: 60)
        let storage = try SQLiteAccountStorage(
            account: account,
            path: path,
            limits: limits,
            retentionClock: clock.now
        )
        let old = ServiceOperationID(ClientOperationID.make(at: clock.now()))
        _ = try storage.reserve(old, request: request(old))
        try storage.finish(.init(id: old, state: "succeeded", result: .null))
        clock.advance(61)
        let recent = ServiceOperationID(ClientOperationID.make(at: clock.now()))
        _ = try storage.reserve(recent, request: request(recent))
        #expect(try storage.operation(old) == nil)
        #expect(throws: ServiceFailure.operationExpired) { try storage.reserve(old, request: request(old)) }
        clock.advance(-61)
        let reopened = try SQLiteAccountStorage(
            account: account,
            path: path,
            limits: limits,
            retentionClock: clock.now
        )
        #expect(throws: ServiceFailure.operationExpired) { try reopened.reserve(old, request: request(old)) }
        #expect(try reopened.reserve(recent, request: request(recent)).state == "accepted")
    }

    @Test func legacyIDsRemainDeduplicatedAndRefuseNewAdmissionAtTheirOwnQuota() throws {
        let clock = RetentionClock()
        let storage = try SQLiteAccountStorage(
            account: account, path: ":memory:", limits: .init(maximumAge: 60, legacyOperationCount: 1),
            retentionClock: clock.now
        )
        let legacy = ServiceOperationID("legacy")
        _ = try storage.reserve(legacy, request: request(legacy))
        try storage.finish(.init(id: legacy, state: "succeeded", result: .null))
        clock.advance(3600)
        let new = ServiceOperationID("another-legacy")
        #expect(throws: ServiceFailure.overloaded) { try storage.reserve(new, request: request(new)) }
        let timed = ServiceOperationID(ClientOperationID.make(at: clock.now()))
        _ = try storage.reserve(timed, request: request(timed))
        #expect(try storage.reserve(legacy, request: request(legacy)).state == "succeeded")
    }

    @Test func journalBytesAndAgeCauseExplicitSnapshotRecovery() throws {
        let clock = RetentionClock()
        let storage = try SQLiteAccountStorage(
            account: account, path: ":memory:", retention: 1000,
            limits: .init(journalBytes: 1024, maximumAge: 60), retentionClock: clock.now
        )
        let initial = try storage.checkpoint()
        for index in 0 ..< 10 {
            _ = try storage.append(
                .backendError(.unknown(String(repeating: "x", count: 300) + "\(index)")),
                live: false
            )
        }
        let gap = try storage.readEvents(after: initial, limit: 100)
        #expect(gap.snapshot != nil)
        let beforeExpiry = gap.checkpoint
        _ = try storage.append(.connectionStateChanged(.connected), live: false)
        #expect(try storage.readEvents(after: beforeExpiry, limit: 100).events.count == 1)
        clock.advance(61)
        _ = try storage.append(.connectionStateChanged(.idle), live: false)
        #expect(try storage.readEvents(after: beforeExpiry, limit: 100).snapshot != nil)
    }

    @Test func resultBudgetFailureKeepsTheOperationUncertainInsteadOfMakingItRetryable() throws {
        let storage = try SQLiteAccountStorage(
            account: account,
            path: ":memory:",
            limits: .init(operationBytes: 1024)
        )
        let id = ServiceOperationID(ClientOperationID.make())
        _ = try storage.reserve(id, request: request(id))
        try storage.finish(.init(id: id, state: "dispatching"))
        #expect(throws: ServiceFailure.operationUnknown) {
            try storage.finish(.init(
                id: id,
                state: "succeeded",
                result: .string(String(repeating: "x", count: 2048))
            ))
        }
        #expect(try storage.reserve(id, request: request(id)).state == "unknown")
    }

    private func request(_ id: ServiceOperationID) throws -> ServiceRequest {
        try ServiceRequest(
            header: .init(requestID: .init(UUID().uuidString), accountID: account),
            payload: SendCommand(
                operationID: id,
                command: .loadMembers(conversationID: .init("chat"))
            )
        )
    }
}

private final class RetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ interval: TimeInterval) {
        lock.withLock { value.addTimeInterval(interval) }
    }
}
