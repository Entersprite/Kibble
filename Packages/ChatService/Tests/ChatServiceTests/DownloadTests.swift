import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct DownloadTests {
    let attachment = Attachment(id: "issued", name: "provider name", contentType: "application/octet-stream")
    let image = URL(string: "https://images.example/issued.png")!

    func seed(_ harness: UploadHarness) async throws -> AccountRuntime {
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        let storage = await runtime.storage
        _ = try storage.append(.messageReceived(Message(
            id: .init("media-message"), conversationID: .init("conversation"), threadID: .init("thread"),
            sender: harness.first.selfID, text: "Issued media", createdAt: Date(timeIntervalSince1970: 100),
            reactions: [.init(
                emoji: ":demo:",
                count: 1,
                customEmoji: .init(id: "emoji", shortcode: "demo", imageToken: "issued-token")
            )],
            attachments: [attachment], links: [.init(
                url: image,
                preview: .init(title: "Image", imageURL: image)
            )]
        )), live: false)
        return runtime
    }

    func begin(
        _ harness: UploadHarness,
        selector: MediaSelector? = nil,
        rendition: String = "file",
        maximum: Int = 200_000
    ) async throws -> DownloadTransfer {
        try await harness.call(BeginDownloadTransfer(
            operationID: .init(UUID().uuidString), selector: selector ?? .attachment(attachment.id),
            rendition: rendition, maximumBytes: maximum
        ), account: harness.first)
    }

    func ready(_ id: ServiceTransferID, harness: UploadHarness) async throws -> DownloadTransfer {
        var latest: DownloadTransfer?
        try await authEventually {
            latest = try await harness.call(GetDownloadTransfer(transferID: id), account: harness.first)
            return latest?.phase == "ready"
        }
        return try #require(latest)
    }

    func read(
        _ id: ServiceTransferID,
        offset: Int64,
        harness: UploadHarness,
        account: AccountRecord? = nil
    ) async throws -> ServiceBinaryReply {
        let request = try harness.request(
            ReadTransferChunk(transferID: id, offset: offset, count: 65536),
            account: account ?? harness.first
        )
        return try await harness.transport.exchangeBinary(request, body: Data())
    }

    @Test func issuedFilesStreamInRawChunksAndShareUploadBudget() async throws {
        let harness = try await UploadHarness.make(limits: .init(
            maximumFileBytes: 200_000,
            maximumAccountBytes: 300_000
        ))
        _ = try await seed(harness)
        let descriptor = try await begin(harness)
        let value = try await ready(descriptor.id, harness: harness)
        #expect(value.byteSize == UploadTestBackend.mediaBytes.count)
        var bytes = Data()
        for offset: Int64 in [0, 65536, 131_072] {
            let reply = try await read(value.id, offset: offset, harness: harness)
            _ = try reply.response.value(for: ReadTransferChunk.self)
            bytes.append(reply.body)
        }
        #expect(bytes == UploadTestBackend.mediaBytes)
        await #expect(throws: ServiceFailure.overloaded) { try await harness.begin(150_000) }
        let foreign = try await read(value.id, offset: 0, harness: harness, account: harness.second)
        #expect(throws: ServiceFailure.transferExpired) {
            try foreign.response.value(for: ReadTransferChunk.self)
        }
        _ = try await harness.call(CancelTransfer(transferID: value.id), account: harness.first)
        #expect(try await harness.begin(200_000).byteSize == 200_000)
        await harness.service.shutdown()
    }

    @Test func arbitrarySourcesRefuseBeforeProviderIOAndEmojiUsesIssuedToken() async throws {
        let harness = try await UploadHarness.make()
        _ = try await seed(harness)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await #expect(throws: ServiceFailure.notAuthorized) { try await begin(
            harness,
            selector: .attachment("forged")
        ) }
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await begin(
                harness,
                selector: .remoteImage(#require(URL(string: "https://images.example/forged.png"))),
                rendition: "image"
            )
        }
        #expect(await provider.mediaAttachments.isEmpty)
        let emoji = try await begin(harness, selector: .customEmoji("emoji"), rendition: "image")
        _ = try await ready(emoji.id, harness: harness)
        #expect(await provider.mediaEmoji.first?.imageToken == "issued-token")
        let remote = try await begin(harness, selector: .remoteImage(image), rendition: "image")
        _ = try await ready(remote.id, harness: harness)
        await harness.service.shutdown()
    }

    @Test func deletionDuringProviderIOCannotPublishItsLateBytes() async throws {
        let harness = try await UploadHarness.make()
        let runtime = try await seed(harness)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdMediaFetch()
        let descriptor = try await begin(harness)
        do {
            try await authEventually { await provider.mediaHeld }
            _ = try await runtime.storage.append(
                .messageDeleted(id: .init("media-message"), in: .init("conversation")),
                live: true
            )
        } catch { await provider.releaseMedia(); await harness.service.shutdown(); throw error }
        await provider.releaseMedia()
        try await authEventually { await runtime.downloads[descriptor.id]?.job == nil }
        #expect(await provider.mediaAcknowledged)
        #expect(await runtime.downloads[descriptor.id]?.descriptor.byteSize == nil)
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.call(GetDownloadTransfer(transferID: descriptor.id), account: harness.first)
        }
        for file in await provider.mediaFiles {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        await harness.service.shutdown()
    }

    @Test func readyTransfersRecheckSourceAndClientOwnershipBeforeEachRead() async throws {
        let harness = try await UploadHarness.make()
        let runtime = try await seed(harness)
        let descriptor = try await begin(harness)
        _ = try await ready(descriptor.id, harness: harness)
        let other = InProcessChatTransport(endpoint: harness.service, context: .init(
            principalID: harness.first.principalID, deviceID: .init("other-device"),
            sessionID: .init("other-session"), accounts: [harness.first.id]
        ))
        _ = try await other.negotiate(.current)
        let request = try harness.request(
            ReadTransferChunk(transferID: descriptor.id, offset: 0, count: 10),
            account: harness.first
        )
        let foreign = try await other.exchangeBinary(request, body: Data())
        #expect(throws: ServiceFailure.notAuthorized) {
            try foreign.response.value(for: ReadTransferChunk.self)
        }
        _ = try await runtime.storage.append(
            .messageDeleted(id: .init("media-message"), in: .init("conversation")),
            live: true
        )
        let revoked = try await read(descriptor.id, offset: 0, harness: harness)
        #expect(revoked.body.isEmpty)
        #expect(throws: ServiceFailure.notAuthorized) {
            try revoked.response.value(for: ReadTransferChunk.self)
        }
        await harness.service.shutdown()
    }

    @Test func disableWaitsForNoncooperativeMediaAndCleansItsOutput() async throws {
        let harness = try await UploadHarness.make()
        let runtime = try await seed(harness)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdMediaFetch()
        let descriptor = try await begin(harness)
        let job = await runtime.downloads[descriptor.id]?.job
        do {
            try await authEventually { await provider.mediaHeld }
        } catch {
            await provider.releaseMedia()
            await harness.service.shutdown()
            throw error
        }
        let disabling = Task { try await harness.call(
            SetAccountEnabled(enabled: false),
            account: harness.first
        ) }
        do {
            try await authEventually {
                try await harness.call(ListAccounts()).first { $0.id == harness.first.id }?
                    .isEnabled == false
            }
        } catch {
            await provider.releaseMedia(); _ = await disabling.result; await harness.service
                .shutdown(); throw error
        }
        await provider.releaseMedia()
        #expect(try await !disabling.value.isEnabled)
        await job?.value
        #expect(await provider.mediaAcknowledged)
        #expect(await runtime.downloads.isEmpty)
        for file in await provider.mediaFiles {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        await harness.service.shutdown()
    }

    @Test func actualFileLimitStillRefusesAProviderThatViolatesItsBound() async throws {
        let harness = try await UploadHarness.make()
        let runtime = try await seed(harness)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdMediaFetch(ignoreLimit: true)
        let descriptor = try await begin(harness, maximum: 1)
        do {
            try await authEventually { await provider.mediaHeld }
        } catch {
            await provider.releaseMedia()
            await harness.service.shutdown()
            throw error
        }
        await provider.releaseMedia()
        try await authEventually { await runtime.downloads[descriptor.id]?.job == nil }
        await #expect(throws: ServiceFailure.frameTooLarge) {
            try await harness.call(GetDownloadTransfer(transferID: descriptor.id), account: harness.first)
        }
        for file in await provider.mediaFiles {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        await harness.service.shutdown()
    }
}
