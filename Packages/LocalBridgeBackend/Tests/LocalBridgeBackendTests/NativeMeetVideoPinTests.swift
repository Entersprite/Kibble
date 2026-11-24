import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
extension NativeMeetVideoTests {
    @Test(arguments: [1, 2])
    func pinsChooseExactLiveStreamsWithoutGrowingTheReceiverSet(_ capacity: Int) async throws {
        let media = VideoFakeMedia()
        media.receiveSlots = capacity
        media.remoteMuted = false
        media.additionalDownstreams = streams(media)
        let transport = ScriptedTransport(responses())
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        let setupRequests = await transport.sent.count
        try await installPinRoster(in: session)
        let handles = await session.participantHandles
        let shared = try #require(handles[resource("shared")])
        let target = try #require(handles[resource("target")])
        let camera = try #require(handles[resource("camera")])

        await session.refreshVideo()
        #expect(Set(media.remoteSlots.compactMap(\.participantID)).contains(shared))
        #expect(!media.remoteSlots.contains { $0.participantID == target })

        media.receivePreferences = CallVideoPreferences(personalPins: [target, camera])
        await session.refreshVideo()
        let withoutDismissal = Set(media.remoteSlots.compactMap(\.participantID))
        #expect(withoutDismissal == (capacity == 1 ? [shared] : [shared, target]))
        let priorIndex = media.remoteSlots.first { $0.participantID == target }?.index

        media.receivePreferences = CallVideoPreferences(
            personalPins: [target, camera],
            dismissedSharedPins: [shared]
        )
        await session.refreshVideo()
        let focused = Set(media.remoteSlots.compactMap(\.participantID))
        #expect(focused == (capacity == 1 ? [target] : [target, camera]))
        #expect(media.remoteSlots.count == capacity)
        if capacity == 2 {
            #expect(media.remoteSlots.first { $0.participantID == target }?.index == priorIndex)
        }
        #expect(media.answers.last?.contains("a=ssrc-group:FID 9501 9502") == true)
        #expect(media.answers.last?.contains("a=ssrc-group:FID 9151 9152") == false)

        media.additionalDownstreams = streams(media, muteTarget: true)
        await session.refreshVideo()
        #expect(media.remoteSlots.contains { $0.participantID == camera && $0.isVisible })
        #expect(!media.remoteSlots.contains { $0.participantID == target })

        try await session.reconcileParticipants(
            makePinRoster(6, includeTarget: false),
            local: resource("one")
        )
        try await session.reconcileParticipants(makePinRoster(7, includeTarget: true), local: resource("one"))
        #expect(await session.participantHandles[resource("target")] != target)
        media.additionalDownstreams = streams(media)
        await session.refreshVideo()
        #expect(media.remoteSlots.contains { $0.participantID == camera && $0.isVisible })
        #expect(media.answers.last?.contains("a=ssrc-group:FID 9501 9502") == false)
        #expect(await transport.sent.count == setupRequests)
        await session.close()
    }

    @Test(arguments: [1, 2])
    func viewerCanReleaseAndRestoreOneVideoWithoutChangingAudioOrAChildPresentation(_ capacity: Int)
        async throws {
        let media = VideoFakeMedia()
        media.receiveSlots = capacity
        media.additionalDownstreams = [
            media.downstream(id: "pinned-camera", primary: 9201, camera: true, device: resource("camera")),
            media.downstream(id: "presentation", primary: 9501, camera: false, device: resource("target"))
        ]
        let transport = ScriptedTransport(responses())
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        try await installPinRoster(in: session)
        let setupRequests = await transport.sent.count
        let handles = await session.participantHandles
        let camera = try #require(handles[resource("camera")])
        let presentation = try #require(handles[resource("target")])
        let pins = [camera, presentation]
        media.receivePreferences = CallVideoPreferences(personalPins: pins)
        await session.refreshVideo()
        #expect(media.remoteSlots.contains { $0.participantID == camera && $0.isVisible })
        let presentationSlot = media.remoteSlots.first { $0.participantID == presentation }?.index

        media.receivePreferences = CallVideoPreferences(personalPins: pins, hiddenVideoFeeds: [camera])
        await session.refreshVideo()
        #expect(!media.remoteSlots.contains { $0.participantID == camera })
        let nextPresentation = try #require(media.remoteSlots.first { $0.participantID == presentation })
        #expect(nextPresentation.isVisible)
        if capacity > 1 {
            #expect(nextPresentation.index == presentationSlot)
        }
        #expect(media.requests.filter { releasesVideo($0, device: resource("camera")) }.count == 1)
        #expect(await session.ready)
        #expect(await session.audioStream != nil)

        media.receivePreferences = CallVideoPreferences(personalPins: pins)
        await session.refreshVideo()
        #expect(media.remoteSlots.contains { $0.participantID == camera && $0.isVisible })
        #expect(await transport.sent.count == setupRequests)
        await session.close()
    }

    private func releasesVideo(_ request: Data, device: String) -> Bool {
        guard let operation = ProtoFieldScan.payloads(ofField: 2, in: request).first,
              let stream = ProtoFieldScan.payloads(ofField: 4, in: operation).first,
              let selection = ProtoFieldScan.payloads(ofField: 9, in: stream).first else { return false }
        return ProtoFieldScan.payloads(ofField: 6, in: stream) == [Data(device.utf8)]
            && ProtoFieldScan.varintValues(ofField: 2, in: selection) == [0]
    }

    private func installPinRoster(in session: NativeMeetCallSession) async throws {
        let poll = await session.videoPoll
        poll?.cancel()
        _ = await poll?.result
        let roster = try makePinRoster(5, includeTarget: true)
        await session.reconcileParticipants(roster, local: resource("one"))
    }

    private func streams(_ media: VideoFakeMedia, muteTarget: Bool = false) -> [Data] {
        [
            media.downstream(id: "shared", primary: 9101, camera: true, device: resource("shared")),
            media.downstream(id: "unmatched", primary: 9151, camera: false, device: resource("camera")),
            media.downstream(id: "pinned-camera", primary: 9201, camera: true, device: resource("camera")),
            media.downstream(id: "default", primary: 9301, camera: false, device: resource("default")),
            media.downstream(
                id: "target", primary: 9501, camera: false, muted: muteTarget, device: resource("target")
            )
        ]
    }

    private func makePinRoster(_ version: UInt64, includeTarget: Bool) throws -> MeetCallCollectionsWire
        .Devices {
        let full = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
            + row("one") + row("shared", pinned: true) + row("camera")
            + row("default", parent: "shared") + (includeTarget ? row("target", parent: "camera") : Data())
        let body = NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full))
        let devices = try MeetCallCollectionsWire.snapshot(from: body.base64EncodedData(), in: "spaces/demo")
            .devices
        return try #require(devices)
    }

    private func row(_ name: String, pinned: Bool = false, parent: String? = nil) -> Data {
        var device = NativeMeetFixture.string(1, resource(name)) + NativeMeetFixture.number(4, 1)
        if let parent {
            device += NativeMeetFixture.string(21, resource(parent)) + NativeMeetFixture.number(25, 2)
        }
        if pinned {
            device += NativeMeetFixture.bytes(52, NativeMeetFixture.number(1, 1))
        }
        return NativeMeetFixture.bytes(2, device)
    }

    private func resource(_ id: String) -> String {
        "spaces/demo/devices/" + id
    }
}
