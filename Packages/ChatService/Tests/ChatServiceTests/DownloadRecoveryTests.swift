import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Synchronization
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct DownloadRecoveryTests {
    let media = DownloadTests()

    @Test func expiryReclaimsDownloadQuotaBeforeAnUploadAndZeroLengthCompletes() async throws {
        let clock = Mutex(Date())
        let harness = try await UploadHarness.make(
            limits: .init(maximumAccountTransfers: 1, lifetime: 60), now: { clock.withLock { $0 } },
            fileFactory: { DirectoryTransferStorageFactory(directory: $0, maximumReservedBytes: 200_000) }
        )
        _ = try await media.seed(harness)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.setMediaLength(0)
        let old = try await media.begin(harness, maximum: 200_000)
        #expect(try await media.ready(old.id, harness: harness).byteSize == 0)
        let empty = try await media.read(old.id, offset: 0, harness: harness)
        #expect(empty.body.isEmpty)
        #expect(try empty.response.value(for: ReadTransferChunk.self).isComplete)
        clock.withLock { $0.addTimeInterval(61) }
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.call(GetDownloadTransfer(transferID: old.id), account: harness.first)
        }
        #expect(try await harness.begin(200_000, operation: "replacement").byteSize == 200_000)
        await harness.service.shutdown()
    }

    @Test func refusedDownloadCleanupRetainsItsSlotUntilCheckedRetry() async throws {
        let failures = CleanupFailureSwitch()
        let harness = try await UploadHarness.make(limits: .init(maximumAccountTransfers: 1), fileFactory: {
            CleanupFailureFactory(
                base: DirectoryTransferStorageFactory(directory: $0, maximumReservedBytes: 200_000),
                failures: failures
            )
        })
        _ = try await media.seed(harness)
        let old = try await media.begin(harness)
        _ = try await media.ready(old.id, harness: harness)
        failures.set(true)
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CancelTransfer(transferID: old.id), account: harness.first)
        }
        await #expect(throws: ServiceFailure.internalFailure) { try await harness.begin(200_000) }
        failures.set(false)
        #expect(try await harness.begin(200_000).byteSize == 200_000)
        await harness.service.shutdown()
    }
}
