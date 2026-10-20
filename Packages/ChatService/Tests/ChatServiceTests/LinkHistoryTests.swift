import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct LinkHistoryTests {
    @Test func terminalHistoryPrunesWithoutForgettingUnfinishedCleanupOrAllowingOldRetries() throws {
        let clock = LinkHistoryClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("registry.sqlite").path
        let limits = AccountRetentionLimits(maximumAge: 60)
        let registry = try SQLiteAccountRegistry(path: path, linkRetention: limits, retentionClock: clock.now)
        let completed = link(
            "completed",
            phase: "completed",
            operation: .init(ClientOperationID.make(at: clock.now()))
        )
        let pending = link(
            "unfinished",
            phase: "installing",
            operation: .init(ClientOperationID.make(at: clock.now()))
        )
        let legacy = link("legacy", phase: "canceled", operation: .init("old-client"))
        for record in [completed, pending, legacy] {
            try registry.saveLink(record)
        }
        clock.advance(61)
        #expect(try registry.pruneLinkHistory() == [completed.id])
        #expect(try Set(registry.links().map(\.id)) == [pending.id, legacy.id])
        #expect(throws: ServiceFailure.operationExpired) {
            try registry.admitNewLinkOperation(completed.operationID, principal: .init("owner"))
        }
        clock.advance(-61)
        let reopened = try SQLiteAccountRegistry(path: path, linkRetention: limits, retentionClock: clock.now)
        #expect(throws: ServiceFailure.operationExpired) {
            try reopened.admitNewLinkOperation(completed.operationID, principal: .init("owner"))
        }
    }

    @Test func legacyLinkReceiptsAreRetainedAndNewLegacyAdmissionIsBounded() throws {
        let registry = try SQLiteAccountRegistry(
            path: ":memory:",
            linkRetention: .init(legacyOperationCount: 1)
        )
        try registry.admitNewLinkOperation(.init("old-client"), principal: .init("owner"))
        let legacy = link("legacy", phase: "canceled", operation: .init("old-client"))
        try registry.saveLink(legacy)
        #expect(try registry.pruneLinkHistory().isEmpty)
        #expect(throws: ServiceFailure.overloaded) {
            try registry.admitNewLinkOperation(.init("other-old-client"), principal: .init("owner"))
        }
        try registry.admitNewLinkOperation(.init(ClientOperationID.make()), principal: .init("owner"))
        #expect(try registry.links().first == legacy)
    }

    private func link(_ id: String, phase: String, operation: ServiceOperationID) -> AccountLinkRecord {
        AccountLinkRecord(
            id: .init(id),
            operationID: operation,
            principalID: .init("owner"),
            deviceID: .init("device"),
            targetAccountID: nil,
            accountID: .init(id),
            generation: id,
            previousGeneration: nil,
            expiresAt: .distantFuture,
            phase: phase
        )
    }
}

private final class LinkHistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ interval: TimeInterval) {
        lock.withLock { value.addTimeInterval(interval) }
    }
}
