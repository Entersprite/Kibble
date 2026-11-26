import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetCaptionTests {
    @Test(arguments: [false, true])
    func keepsCaptionsLocalToTheAssignedChannelAndAppliesVersions(compressed: Bool) async throws {
        let (session, media) = try await connectedSession(compressed: compressed)
        let handler = try #require(media.eventHandler)
        let label = "captions_v2"
        #expect(await session.activities.availableActions.contains("captions"))
        #expect(await session.activities.captions == nil)
        await handler(.activityData(channel: label, data: update("Before opt-in", version: 0)))
        #expect(media.sentActivityFrames.isEmpty)

        media.activityReplies = [reply(1, result: 4), reply(2, result: 3)]
        try await session.performActivity(CallActivity("captions", options: ["en-US", "fr-FR"]))
        #expect(await session.activities.captions?.displayLanguage == "fr-FR")
        #expect(media.sentActivityFrames.map(\.0) == [label, label])

        await handler(.activityData(channel: "meet_messages", data: update("Wrong stream", version: 8)))
        await handler(.activityData(channel: label, data: update("Bon", version: 1)))
        let firstID = await session.activities.captions?.segments.first?.id
        await handler(.activityData(channel: label, data: update("Bonjour", version: 2)))
        await handler(.activityData(channel: label, data: update("Stale", version: 1)))
        let segments = await session.activities.captions?.segments
        #expect(segments?.map(\.text) == ["Bonjour"] && segments?.first?.id == firstID)
        #expect(media.sentActivityFrames.count == 4)
        let ack = try #require(media.sentActivityFrames.last?.1)
        #expect(ack == Data([10, 6, 8, 17, 16, 2, 24, 1]))

        media.activityReply = reply(3, result: 3)
        try await session.performActivity(CallActivity("captions", enabled: false))
        #expect(await session.activities.captions == nil)
        await handler(.activityClosed(channel: label))
        #expect(await session.activities.availableActions.contains("captions") == false)
        #expect(await session.ready && media.isConnected)
        await session.close()
    }

    @Test func rejectedConfigurationNeverPublishesAnEnabledState() async throws {
        let (session, media) = try await connectedSession()
        media.activityReplies = [reply(1, result: 4), reply(2, result: 3, code: 7)]
        await #expect(throws: MeetCaptionWire.CommandError.rejected) {
            try await session.performActivity(CallActivity("captions", options: ["en-US", "en-US"]))
        }
        #expect(await session.activities.captions == nil && media.sentActivityFrames.count == 2)
        await session.close()
    }

    @Test func catalogFromTheOwningDeviceYieldsToNewerCaptionSettings() async throws {
        let device = NativeMeetFixture.string(31, "hu-HU") + NativeMeetFixture.bytes(
            33, NativeMeetFixture.string(1, "hu-HU") + NativeMeetFixture.string(2, "sk-SK")
        )
        let (session, media) = try await connectedSession(deviceLanguages: device)
        #expect(await session.activities.captionLanguages?.translations == ["hu-HU": ["sk-SK"]])
        let handler = try #require(media.eventHandler)
        let oldPair = CallActivity("captions", options: ["hu-HU", "sk-SK"])
        let newPair = CallActivity("captions", options: ["hu-HU", "fr-FR"])
        await #expect(throws: ChatError.self) { try await session.performActivity(newPair) }
        #expect(media.sentActivityFrames.isEmpty)

        media.activityReply = reply(2, result: 4) + settings(version: 3, target: "fr-FR")
        await #expect(throws: ChatError.self) { try await session.performActivity(oldPair) }
        #expect(await session.activities.captionLanguages?.translations == ["hu-HU": ["fr-FR"]])
        #expect(await session.activities.captions == nil)
        #expect(media.sentActivityFrames.count == 2)
        #expect(media.sentActivityFrames.last?.1 == Data([10, 4, 16, 3, 32, 1]))

        await handler(.activityData(channel: "captions_v2", data: settings(version: 2, target: "sk-SK")))
        #expect(media.sentActivityFrames.count == 2)
        media.activityReply = reply(4, result: 3)
        try await session.performActivity(newPair)
        #expect(await session.activities.captions?.displayLanguage == "fr-FR")

        await handler(.activityClosed(channel: "captions_v2"))
        let closed = await session.activities
        #expect(closed.captionLanguages == nil && closed.captions == nil)
        await session.close()
    }

    @Test func partialDeviceCatalogKeepsPreviouslyAdvertisedTranslationPairs() async throws {
        let english = NativeMeetFixture.string(31, "en-US")
        let french = NativeMeetFixture.string(31, "fr-FR")
        let source = NativeMeetFixture.string(1, "en-US")
        let original = english + NativeMeetFixture.bytes(33, source + NativeMeetFixture.string(2, "es-ES"))
        let replacement = english + NativeMeetFixture.bytes(33, source + NativeMeetFixture.string(2, "fr-FR"))
        let (session, media) = try await connectedSession(
            deviceLanguages: original,
            deviceCatalogUpdates: [
                english + french,
                replacement,
                english + NativeMeetFixture.bytes(33, source)
            ]
        )

        await session.refreshState()
        #expect(await session.activities.captionLanguages == CallCaptionLanguages(
            live: ["en-US", "fr-FR"], translations: ["en-US": ["es-ES"]]
        ))
        media.activityReplies = [reply(1, result: 4), reply(2, result: 3)]
        try await session.performActivity(CallActivity("captions", options: ["en-US", "es-ES"]))
        #expect(await session.activities.captions?.displayLanguage == "es-ES")

        await session.refreshState()
        #expect(await session.activities.captionLanguages?.translations == ["en-US": ["fr-FR"]])

        await session.refreshState()
        #expect(await session.activities.captionLanguages?.translations.isEmpty == true)
        await session.close()
    }

    @Test func translationOnlyDeviceReportsKeepLiveLanguagesAndCanClearPairs() async throws {
        let english = NativeMeetFixture.string(31, "en-US")
        let source = NativeMeetFixture.string(1, "en-US")
        let spanishPair = NativeMeetFixture.bytes(33, source + NativeMeetFixture.string(2, "es-ES"))
        let frenchPair = NativeMeetFixture.bytes(33, source + NativeMeetFixture.string(2, "fr-FR"))
        let clear = NativeMeetFixture.bytes(33, source)
        let (session, _) = try await connectedSession(
            deviceLanguages: english + spanishPair,
            deviceCatalogUpdates: [frenchPair, clear]
        )

        await session.refreshState()
        let replaced = await session.activities
        #expect(replaced.captionLanguages == CallCaptionLanguages(
            live: ["en-US"], translations: ["en-US": ["fr-FR"]]
        ))
        #expect(replaced.recordingCaptionLanguages == ["en-US"])

        await session.refreshState()
        let cleared = await session.activities
        #expect(cleared.captionLanguages == CallCaptionLanguages(live: ["en-US"], translations: [:]))
        #expect(cleared.recordingCaptionLanguages == ["en-US"])
        await session.close()
    }

    private func connectedSession(
        compressed: Bool = false, deviceLanguages: Data = Data(), deviceCatalogUpdates: [Data] = []
    ) async throws
        -> (NativeMeetCallSession, NativeFakeMedia) {
        let descriptor = NativeMeetFixture.string(1, "captions_v2")
            + NativeMeetFixture.number(2, 1) + NativeMeetFixture.number(3, 43)
            + NativeMeetFixture.number(7, compressed ? 2 : 1)
        let assignment = NativeMeetFixture.bytes(12, descriptor)
        var responses = NativeMeetFixture.responses(activityChannels: assignment)
        responses[3] = NativeMeetFixture.ok(
            NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
                + deviceLanguages,
            token: "30;joined"
        )
        let catalogs = deviceCatalogUpdates.enumerated().map { index, languages in
            let own = NativeMeetFixture.string(1, "spaces/demo/devices/one")
                + NativeMeetFixture.number(4, 1) + languages
            let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, UInt64(index + 1)))
            let full = metadata + NativeMeetFixture.bytes(2, own)
            return NativeMeetFixture.ok(NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full)))
        }
        responses.insert(contentsOf: catalogs, at: 4)
        let transport = ScriptedTransport(responses)
        let media = NativeFakeMedia()
        media.supportsActivityChannelAssignments = true
        media.supportsGzipActivityChannels = compressed
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        let compression: CallDataChannelCompression = compressed ? .gzip : .none
        #expect(media.activityChannelAssignments["captions_v2"]?.compression == compression)
        let sent = await transport.sent
        let request = try #require(sent.first { $0.url.path.hasSuffix("CreateMediaSession") }?.body)
        let envelope = try #require(ProtoFieldScan.payloads(ofField: 1, in: request).first)
        let configuration = try #require(ProtoFieldScan.payloads(ofField: 3, in: envelope).first)
        let offer = try #require(ProtoFieldScan.payloads(ofField: 17, in: configuration).last)
        #expect(ProtoFieldScan.payloads(ofField: 7, in: offer) == (compressed ? [Data([1, 2])] : []))
        await session.startMonitoring(receive: { _ in })
        return (session, media)
    }

    private func settings(version: UInt64, target: String) -> Data {
        let pair = NativeMeetFixture.string(1, "hu-HU") + NativeMeetFixture.string(2, target)
        let languages = NativeMeetFixture.string(1, "hu-HU") + NativeMeetFixture.bytes(3, pair)
        return NativeMeetFixture.bytes(
            1, NativeMeetFixture.number(2, version) + NativeMeetFixture.bytes(4, languages)
        )
    }

    private func reply(_ sequence: UInt64, result: UInt64, code: UInt64 = 0) -> Data {
        let status = NativeMeetFixture.bytes(2, NativeMeetFixture.number(1, code))
        return NativeMeetFixture.bytes(
            2, NativeMeetFixture.number(1, sequence) + status + NativeMeetFixture.bytes(result, Data())
        )
    }

    private func update(_ text: String, version: UInt64) -> Data {
        NativeMeetFixture.bytes(
            1, NativeMeetFixture.number(1, 17) + NativeMeetFixture.number(2, version)
                + NativeMeetFixture.bytes(3, NativeMeetFixture.string(3, text))
        )
    }
}
