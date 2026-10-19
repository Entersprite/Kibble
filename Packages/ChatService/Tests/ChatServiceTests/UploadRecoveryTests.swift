import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct UploadRecoveryTests {
    @Test func abandonedUploadExpiresAndFreesItsSlotAndActualDiskReservation() async throws {
        let clock = Mutex(Date())
        let harness = try await UploadHarness.make(
            limits: .init(maximumAccountTransfers: 1, lifetime: 60), now: { clock.withLock { $0 } },
            fileFactory: { DirectoryTransferStorageFactory(directory: $0, maximumReservedBytes: 4) }
        )
        let old = try await harness.begin(4)
        try await harness.write(old, bytes: Data([1, 2, 3, 4]))
        clock.withLock { $0.addTimeInterval(61) }
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.write(old, bytes: Data([1]))
        }
        let replacement = try await harness.begin(4, operation: "replacement")
        #expect(replacement.id != old.id)
        try await harness.write(replacement, bytes: Data([4, 3, 2, 1]))
        await harness.service.shutdown()
    }

    @Test func refusedCleanupIsVisibleRetainsReservationAndRemovalCanBeRetried() async throws {
        let failures = CleanupFailureSwitch()
        let harness = try await UploadHarness.make(fileFactory: {
            CleanupFailureFactory(base: DirectoryTransferStorageFactory(directory: $0), failures: failures)
        })
        let transfer = try await harness.begin(4)
        try await harness.write(transfer, bytes: Data([1, 2, 3, 4]))
        failures.set(true)
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CancelTransfer(transferID: transfer.id), account: harness.first)
        }
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(RemoveAccount(), account: harness.first)
        }
        #expect(try await harness.call(ListAccounts()).first { $0.id == harness.first.id }?
            .isRemoving == true)
        failures.set(false)
        _ = try await harness.call(RemoveAccount(), account: harness.first)
        #expect(try await !harness.call(ListAccounts()).contains { $0.id == harness.first.id })
        // A second account still admits uploads after the first account's retry.
        _ = try await harness.call(LoadConversations(), account: harness.second)
        _ = try await harness.begin(4, account: harness.second)
        await harness.service.shutdown()
    }

    @Test func allocationFailureRetainsAnUnpublishedHandleForCheckedCleanup() async throws {
        let failures = CleanupFailureSwitch()
        let harness = try await UploadHarness.make(fileFactory: {
            CleanupFailureFactory(
                base: DirectoryTransferStorageFactory(directory: $0, maximumReservedBytes: 4),
                failures: failures
            )
        })
        failures.setCreation(true)
        await #expect(throws: ServiceFailure.internalFailure) { try await harness.begin(4) }
        failures.setCreation(false)
        let recovered = try await harness.begin(4, operation: "replacement")
        try await harness.write(recovered, bytes: Data([1, 2, 3, 4]))
        await harness.service.shutdown()
    }

    @Test func completedReferencesAreAccountConversationAndExpiryScopedAcrossReopen() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        let attachment = Attachment(id: "uploaded", name: "file", contentType: "text/plain", byteSize: 4)
        try save(attachment, at: file)
        let reopened = try SQLiteAccountStorage(account: .init("account"), path: file.path)
        #expect(try reopened.uploadedAttachment("uploaded", in: .init("conversation"), at: Date(
            timeIntervalSince1970: 5
        )) == attachment)
        #expect(try reopened.uploadedAttachment(
            "uploaded",
            in: .init("other"),
            at: Date(timeIntervalSince1970: 5)
        ) == nil)
        #expect(try reopened.uploadedAttachment("uploaded", in: .init("conversation"), at: Date(
            timeIntervalSince1970: 10
        )) == nil)
        let other = try SQLiteAccountStorage(account: .init("other-account"), path: ":memory:")
        #expect(try other.uploadedAttachment(
            "uploaded",
            in: .init("conversation"),
            at: Date(timeIntervalSince1970: 5)
        ) == nil)
    }

    private func save(_ attachment: ChatKit.Attachment, at file: URL) throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: file.path)
        try store.rememberUpload(
            attachment,
            in: .init("conversation"),
            at: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 10)
        )
    }
}

final class CleanupFailureSwitch: Sendable {
    struct State { var cleanup = false; var creation = false }
    private let failed = Mutex(State())
    func set(_ value: Bool) {
        failed.withLock { $0.cleanup = value }
    }

    func setCreation(_ value: Bool) {
        failed.withLock { $0.creation = value }
    }

    func check() throws {
        if failed.withLock({ $0.cleanup }) {
            throw ServiceFailure.internalFailure
        }
    }

    func checkCreation() throws {
        if failed.withLock({ $0.creation }) {
            throw ServiceFailure.internalFailure
        }
    }
}

struct CleanupFailureFactory: ServiceTransferStorageFactory {
    let base: DirectoryTransferStorageFactory
    let failures: CleanupFailureSwitch
    func open(_ account: ConnectedAccountID) throws -> any ServiceTransferStorage {
        try CleanupFailureStorage(base: base.open(account), failures: failures)
    }

    func erase(_ account: ConnectedAccountID) throws {
        try failures.check(); try base.erase(account)
    }
}

struct CleanupFailureStorage: ServiceTransferStorage {
    let base: any ServiceTransferStorage
    let failures: CleanupFailureSwitch
    func create(_ id: ServiceTransferID, maximumBytes: Int) throws {
        try base.create(id, maximumBytes: maximumBytes)
        try failures.checkCreation()
    }

    func append(_ bytes: Data, to id: ServiceTransferID, at offset: Int64) throws {
        try base.append(bytes, to: id, at: offset)
    }

    func read(_ id: ServiceTransferID, at offset: Int64, count: Int) throws -> Data {
        try base.read(
            id,
            at: offset,
            count: count
        )
    }

    func file(_ id: ServiceTransferID, expectedBytes: Int) throws -> URL {
        try base.file(
            id,
            expectedBytes: expectedBytes
        )
    }

    func remove(_ id: ServiceTransferID) throws {
        try failures.check(); try base.remove(id)
    }

    func close() throws {
        try failures.check(); try base.close()
    }
}
