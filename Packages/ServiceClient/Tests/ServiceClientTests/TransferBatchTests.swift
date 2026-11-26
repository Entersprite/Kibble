import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct TransferBatchTests {
    @Test func aBatchLargerThanEightImagesWaitsThenReadsEveryImageThroughTheService() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let attachment = try await DownloadClientTests().issued(harness)
        let backend = harness.backend(harness.first)
        let queue = await backend.transferQueue
        var held: [UUID] = []
        for _ in 0 ..< 8 {
            try await held.append(queue.acquire(.media))
        }
        let jobs = (0 ..< 16).map { _ in Task {
            try await backend.attachmentData(attachment, size: .preview)
        } }
        do {
            try await eventually {
                let queued = await queue.queuedCount
                let owned = await backend.mediaTasks.count
                return queued == 16 && owned == 16
            }
        } catch {
            for job in jobs {
                job.cancel()
            }
            for permit in held {
                await queue.release(permit)
            }
            await backend.disconnect(); await harness.service.shutdown()
            throw error
        }
        #expect(await queue.active.count == 8)
        for permit in held {
            await queue.release(permit)
        }
        for job in jobs {
            #expect(try await job.value.starts(with: Data([137, 80, 78, 71])))
        }
        #expect(await backend.mediaTasks.isEmpty)
        #expect(await queue.active.isEmpty)
        #expect(await queue.queuedCount == 0)
        await backend.disconnect(); await harness.service.shutdown()
    }

    @Test func disconnectCancelsQueuedImagesBeforeTheyCanIssueAServiceRequest() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let tap = DownloadClientTests().tap(harness)
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let queue = await backend.transferQueue
        var held: [UUID] = []
        for _ in 0 ..< 8 {
            try await held.append(queue.acquire(.media))
        }
        let attachment = Attachment(id: "unissued", name: "image", contentType: "image/png")
        let jobs = (0 ..< 16).map { _ in Task {
            try await backend.attachmentData(attachment, size: .preview)
        } }
        do {
            try await eventually { await queue.queuedCount == 16 }
        } catch {
            for job in jobs {
                job.cancel()
            }
            for permit in held {
                await queue.release(permit)
            }
            await backend.disconnect(); await harness.service.shutdown()
            throw error
        }
        await backend.disconnect()
        for job in jobs {
            await #expect(throws: CancellationError.self) { try await job.value }
        }
        #expect(await tap.requests.isEmpty)
        #expect(await backend.mediaTasks.isEmpty)
        #expect(await queue.queuedCount == 0)
        for permit in held {
            await queue.release(permit)
        }
        #expect(await queue.active.isEmpty)
        await harness.service.shutdown()
    }
}
