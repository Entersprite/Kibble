import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Synchronization
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct DownloadClientTests {
    func issued(_ harness: ClientHarness) async throws -> ChatKit.Attachment {
        let backend = harness.backend(harness.first)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        let attachment = try await backend.uploadAttachment(OutgoingAttachment(
            id: "chosen", file: file, name: "test.pdf", contentType: "application/pdf", byteSize: 3
        ), to: .init("same"), progress: { _ in })
        try await backend.send(.sendMessage(
            conversationID: .init("same"),
            threadID: nil,
            text: "File",
            localID: nil,
            attachments: [attachment]
        ))
        let catalog = try #require(try await harness.canonical(harness.first.id) as? any ServiceMediaCatalog)
        try await eventually { try !catalog.mediaSources(for: .attachment(attachment.id), at: Date()).isEmpty
        }
        await backend.disconnect()
        return attachment
    }

    func tap(_ harness: ClientHarness) -> DownloadTransportTap {
        DownloadTransportTap(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
    }

    func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    @Test func realServiceFilesAndPicturesTravelOnlyThroughTheAPI() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let attachment = try await issued(harness)
        let tap = tap(harness)
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let file = destination()
        let progress = Mutex<[Int]>([])
        try await backend.downloadAttachment(attachment, to: file, progress: { value in
            progress.withLock { $0.append(value.bytesReceived) }
        })
        let bytes = try Data(contentsOf: file)
        #expect(bytes.starts(with: Data("%PDF".utf8)))
        #expect(await bytes == (tap.chunks).reduce(Data(), +))
        #expect(await tap.chunks.count > 4)
        #expect(progress.withLock { $0.last } == bytes.count)
        #expect(try await backend.attachmentData(attachment, size: .preview).starts(with: Data([
            137,
            80,
            78,
            71
        ])))
        let photo = try #require(URL(string: "https://acme.example/profile.png"))
        let canonical = try await harness.canonical(harness.first.id)
        _ = try canonical.append(
            .membersChanged(
                conversationID: .init("same"),
                members: [Member(id: .init("peer"), kind: .human, avatarURL: photo)]
            ),
            live: false
        )
        #expect(try await backend.remoteImage(photo).starts(with: Data([137, 80, 78, 71])))
        let foreign = harness.backend(harness.second)
        await #expect(throws: ServiceFailure.notAuthorized) { try await foreign.attachmentData(
            attachment,
            size: .original
        ) }
        await #expect(throws: ServiceFailure.notAuthorized) { try await foreign.remoteImage(photo) }
        for request in await tap.requests {
            let json = try String(decoding: ServiceCodec.encode(request), as: UTF8.self)
            #expect(!json.contains(file.path))
        }
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        #expect(await runtime.downloads.isEmpty)
        await backend.disconnect(); await foreign.disconnect(); await harness.service.shutdown()
    }

    @Test func interruptedChunksRemoveOnlyTheirOwnPartialFileAndReleaseReservation() async throws {
        let harness = try await ClientHarness.make(
            uploads: true,
            transferLimits: .init(maximumAccountTransfers: 1)
        )
        let attachment = try await issued(harness)
        let tap = tap(harness)
        await tap.failAfterFirstChunk()
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let file = destination()
        await #expect(throws: ServiceFailure.invalidResponse) {
            try await backend.downloadAttachment(attachment, to: file, progress: { _ in })
        }
        #expect(await tap.chunks.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let existing = destination()
        try Data("preserve".utf8).write(to: existing)
        await #expect(throws: (any Error).self) {
            try await backend.downloadAttachment(attachment, to: existing, progress: { _ in })
        }
        #expect(try Data(contentsOf: existing) == Data("preserve".utf8))
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        #expect(await runtime.downloads.isEmpty)
        await backend.disconnect(); await harness.service.shutdown()
    }

    @Test func disconnectDrainsHeldReadWithoutWritingIntoTheRetiredDestination() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let attachment = try await issued(harness)
        let tap = tap(harness)
        await tap.holdAfterFirstChunk()
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let file = destination()
        let download = Task { try await backend.downloadAttachment(attachment, to: file, progress: { _ in }) }
        do {
            try await eventually { await tap.held }
        } catch {
            await tap.release(); _ = await download.result; await backend.disconnect(); await harness.service
                .shutdown(); throw error
        }
        #expect(try Data(contentsOf: file).count == 7)
        let generation = await backend.connectionGeneration
        let stopping = Task { await backend.disconnect() }
        do {
            try await eventually { await backend.connectionGeneration != generation }
        } catch {
            await tap.release(); _ = await download.result; await stopping.value; await harness.service
                .shutdown(); throw error
        }
        await tap.release()
        await #expect(throws: CancellationError.self) { try await download.value }
        await stopping.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        #expect(await runtime.downloads.isEmpty)
        await harness.service.shutdown()
    }
}
