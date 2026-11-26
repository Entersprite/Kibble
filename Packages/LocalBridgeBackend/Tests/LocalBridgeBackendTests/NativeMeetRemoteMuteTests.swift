import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetRemoteMuteTests {
    private let own = "spaces/demo/devices/one"
    private let peer = "spaces/demo/devices/two"
    private let other = "spaces/demo/devices/three"
    private let mask = "audio_mute_request.by_meeting_device_id"

    @Test func moderatorRequestMutesBeforeClearingAndFreshRequestsCanMuteAgain() async throws {
        let media = NativeFakeMedia()
        let pending = device(own, role: 3, requester: peer)
        let clear = device(own, role: 3)
        let received = NativeMeetFixture.ok(clear)
        let (session, transport) = try await connect([
            snapshot(1, local: pending), received, snapshot(2, local: pending),
            snapshot(3, local: clear), snapshot(4, local: pending), received
        ], media: media)
        await session.refreshState()
        #expect(media.isMicrophoneMuted && media.isConnected)
        let first = try #require(await session.activities.moderatorMute)
        let calls = await transport.sent.dropFirst(4)
        let ack = try #require(calls.last)
        #expect(ack.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(ack.body == update(own, requester: nil))
        _ = try await session.setMuted(false)
        await session.refreshState()
        #expect(await session.activities.moderatorMute == first)
        #expect(!media.isMicrophoneMuted)
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
            .count == 1)
        await session.refreshState()
        await session.refreshState()
        #expect(media.isMicrophoneMuted && media.isConnected)
        #expect(await session.activities.moderatorMute != first)
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
            .count == 2)
        await session.close()
    }

    @Test func onlyTheLocalDeviceCanDeliverAMuteRequestFromTheCurrentSpace() async throws {
        let media = NativeFakeMedia()
        let foreign = device(own, role: 3, requester: "spaces/foreign/devices/host")
        let remote = device(peer, requester: own)
        let (session, transport) = try await connect(
            [snapshot(1, local: foreign, peers: [remote])],
            media: media
        )
        await session.refreshState()
        #expect(!media.isMicrophoneMuted)
        #expect(await session.activities.moderatorMute == nil)
        #expect(await transport.sent.dropFirst(4)
            .allSatisfy { $0.url.lastPathComponent != "UpdateMeetingDevice" })
        await session.close()
    }

    @Test func aHeldUnmuteAcknowledgementCannotSupersedeModeratorMute() async throws {
        let media = StreamFakeMedia()
        let pendingRequest = device(own, role: 3, requester: peer)
        let (session, _) = try await connect([
            snapshot(1, local: pendingRequest), NativeMeetFixture.ok(device(own, role: 3))
        ], media: media)
        #expect(try await session.setMuted(true))
        media.holdMute = true
        defer { media.holdMute = false; media.resume() }
        let pending = Task { try await session.setMuted(false) }
        for _ in 0 ..< 1000 where media.pending == nil {
            await Task.yield()
        }
        _ = try #require(media.pending)
        #expect(!media.isMicrophoneMuted)

        await session.refreshState()
        #expect(media.isMicrophoneMuted)
        media.holdMute = false
        media.resume()
        #expect(try await !pending.value)
        #expect(await session.streamTask?.value == true)
        let request = try #require(media.requests.last)
        let modify = try #require(ProtoFieldScan.payloads(ofField: 2, in: request).first)
        let stream = try #require(ProtoFieldScan.payloads(ofField: 4, in: modify).first)
        let mute = try #require(ProtoFieldScan.payloads(ofField: 10, in: stream).first)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: mute) == [1])
        #expect(media.isMicrophoneMuted)
        #expect(try await session.setMuted(false))
        #expect(!media.isMicrophoneMuted)
        await session.close()
    }

    @Test func aCohostCanRequestOneMuteWithoutChangingTheObservedMicrophone() async throws {
        let before = snapshot(1, local: device(own, role: 5))
        let accepted = NativeMeetFixture.ok(device(peer, requester: own))
        let (session, transport) = try await connect([before, before, accepted])
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        #expect(await session.activities.availableActions.contains("muteParticipant"))
        #expect(await !session.activities.availableActions.contains("muteAllParticipants"))
        try await session.performActivity(CallActivity("muteParticipant", resourceID: id))
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(request.body == update(peer, requester: own))
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(await session.publishedParticipants?.first { $0.id == id }?.microphoneMuted == nil)
        await session.close()
    }

    @Test(arguments: [true, false])
    func bulkMuteAddressesOnlyOtherJoinedDevicesAndDetectsPartialAcceptance(allAccepted: Bool) async throws {
        let before = snapshot(1, peers: [
            device(peer), device(other),
            device("spaces/demo/devices/presenter") + NativeMeetFixture.number(25, 2)
        ])
        let accepted = NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(3, device(peer, requester: own)))
        let additional = allAccepted
            ? NativeMeetFixture.bytes(3, device(other, requester: own))
            : NativeMeetFixture.string(1, other) + NativeMeetFixture.bytes(2, NativeMeetFixture.number(1, 7))
        let receipt = NativeMeetFixture.ok(accepted + NativeMeetFixture.bytes(1, additional))
        let (session, transport) = try await connect([before, before, receipt])
        await session.refreshState()
        if allAccepted {
            try await session.performActivity(CallActivity("muteAllParticipants"))
        } else {
            await #expect(throws: ChatError.self) {
                try await session.performActivity(CallActivity("muteAllParticipants"))
            }
        }
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "BulkUpdateMeetingDevices")
        let encoded = NativeMeetFixture.string(1, "spaces/demo")
            + NativeMeetFixture.string(2, other) + NativeMeetFixture.string(2, peer)
            + NativeMeetFixture.bytes(3, muteValue(own))
            + NativeMeetFixture.bytes(4, NativeMeetFixture.string(1, mask))
        #expect(request.body == encoded)
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "BulkUpdateMeetingDevices" }
            .count == 1)
        await session.close()
    }

    private func connect(
        _ responses: [Result<HTTPResponse, any Error>],
        media: any CallMediaEngine = NativeFakeMedia()
    )
        async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses().map { response in
            response.map {
                HTTPResponse(status: $0.status, headers: HTTPHeaders(fields: $0.headers.fields + [
                    .init(name: "x-goog-meeting-debugid", value: "synthetic-conference")
                ]), body: $0.body)
            }
        }
        let transport = ScriptedTransport(Array(setup.prefix(4)) + responses + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        return (session, transport)
    }

    private func snapshot(_ version: UInt64, local: Data? = nil, peers: [Data]? = nil)
        -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let settings = NativeMeetFixture.bytes(11, NativeMeetFixture.number(7, 1))
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, settings)
        let devices = ([local ?? device(own, role: 1)] + (peers ?? [device(peer)])).reduce(into: metadata) {
            $0 += NativeMeetFixture.bytes(2, $1)
        }
        return NativeMeetFixture.ok(
            NativeMeetFixture.bytes(
                1,
                NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, space))
            )
                + NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, devices))
        )
    }

    private func device(_ name: String, role: UInt64 = 3, requester: String? = nil) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.number(4, 1)
            + NativeMeetFixture.number(46, role) + (requester.map { muteValue($0) } ?? Data())
    }

    private func muteValue(_ requester: String?) -> Data {
        NativeMeetFixture.bytes(12, requester.map { NativeMeetFixture.string(1, $0) } ?? Data())
    }

    private func update(_ name: String, requester: String?) -> Data {
        NativeMeetFixture.bytes(1, NativeMeetFixture.string(1, name) + muteValue(requester))
            + NativeMeetFixture.bytes(2, NativeMeetFixture.string(1, mask))
    }
}
