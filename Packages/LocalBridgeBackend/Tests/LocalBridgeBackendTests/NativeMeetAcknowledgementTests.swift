import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetAcknowledgementTests {
    @Test func returnedNoticesRequireConfirmationBeforeAckAndJoinContinuation() async throws {
        let transport = ScriptedTransport(responses(types: [1, 3]))
        let media = StreamFakeMedia()
        media.admissionConfirmation = { notices in
            #expect(notices == [.recording, .transcription])
            #expect(media.requests.isEmpty)
            #expect(await transport.sent.count == 5)
            return true
        }
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(media.requests.count == 1 && media.admissionNotices.count == 1)
        await session.close()
        let sent = await transport.sent
        #expect(sent.count == 8)
        let ack = try #require(sent[5].body)
        let value = try #require(ProtoFieldScan.payloads(ofField: 1, in: ack).first)
        #expect(ProtoFieldScan.fields(in: ack).fields.map(\.number) == [1])
        #expect(ProtoFieldScan.fields(in: value).fields.map(\.number) == [1, 41, 41])
        let requirements = ProtoFieldScan.payloads(ofField: 41, in: value)
        #expect(requirements.map { ProtoFieldScan.varintValues(ofField: 1, in: $0) } == [[1], [3]])
        #expect(requirements.allSatisfy { ProtoFieldScan.varintValues(ofField: 2, in: $0) == [2] })
        #expect(sent[6].headers["x-goog-meeting-token"] == "40;acknowledged")
        #expect(await session.takeReport().contains { $0.contains("notice acknowledged; continuing Join") })
    }

    @Test func decliningClosesTheNativeDeviceWithoutSendingAnAcknowledgement() async throws {
        let transport = ScriptedTransport(responses(types: [1], continuation: false))
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: CancellationError.self) { try await session.connect() }
        #expect(media.admissionNotices == [[.recording]])
        #expect(media.requests.isEmpty && media.closed)
        #expect(await transport.sent.count == 6)
    }

    @Test(arguments: [[UInt64(99)], [1, 99], []])
    func unsupportedOrMissingRequirementsCannotBeSilentlyAcknowledged(_ types: [UInt64]) async throws {
        let transport = ScriptedTransport(responses(types: types, continuation: false))
        let media = StreamFakeMedia()
        media
            .admissionConfirmation = { _ in
                Issue.record("No notice may be shown for unknown requirements"); return true
            }
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.connect() }
        #expect(media.admissionNotices.isEmpty && media.requests.isEmpty && media.closed)
        #expect(await transport.sent.count == 6)
    }

    @Test func aRepeatedPendingRequirementCannotReplayTheAcknowledgement() async throws {
        var scripted = responses(types: [3])
        scripted[6] = device(state: 9, types: [3], token: "50;still-pending")
        scripted.insert(collection(types: [3]), at: 7)
        let transport = ScriptedTransport(scripted)
        let media = StreamFakeMedia()
        media.admissionConfirmation = { _ in true }
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.connect() }
        #expect(media.admissionNotices.count == 1 && media.requests.isEmpty && media.closed)
        #expect(await transport.sent.count == 9)
    }

    @Test func transportLossDuringConfirmationCannotSubmitTheAcknowledgement() async throws {
        let transport = ScriptedTransport(responses(types: [1], continuation: false))
        let media = StreamFakeMedia()
        media.admissionConfirmation = { _ in media.isConnected = false; return true }
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: CallMediaError.connectionFailed) { try await session.connect() }
        #expect(media.requests.isEmpty)
        #expect(await transport.sent.count == 6)
    }

    @Test func aRefusedAcknowledgementIsNeverRetriedOrFollowedByAnotherJoin() async throws {
        var values = responses(types: [1], continuation: false)
        values.insert(.success(HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())), at: 5)
        let transport = ScriptedTransport(values)
        let media = StreamFakeMedia()
        media.admissionConfirmation = { _ in true }
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: (any Error).self) { try await session.connect() }
        #expect(media.admissionNotices.count == 1 && media.requests.isEmpty && media.closed)
        #expect(await transport.sent.count == 7)
    }

    @Test func aFreshConfirmationOfTheExactNativeDeviceNeedsNoNoticeOrRepeatedJoin() async throws {
        var values = responses(types: [], continuation: false)
        values[4] = collection(types: [], state: 1)
        let transport = ScriptedTransport(values)
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(media.admissionNotices.isEmpty && media.requests.count == 1)
        await session.close()
        #expect(await transport.sent.count == 6)
    }

    private func responses(types: [UInt64], continuation: Bool = true) -> [Result<HTTPResponse, any Error>] {
        var values = NativeMeetFixture.responses(deviceTransfer: 3)
        values[3] = device(state: 9, types: [], token: "30;notices")
        values.insert(collection(types: types), at: 4)
        if continuation {
            values.insert(device(state: 9, types: [], token: "40;acknowledged"), at: 5)
            values.insert(device(state: 1, types: [], token: "50;joined"), at: 6)
        }
        return values.map { $0.map { HTTPResponse(
            status: $0.status,
            headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                name: "X-Goog-Meeting-Debugid", value: "conference-sentinel"
            )]), body: $0.body
        ) } }
    }

    private func collection(types: [UInt64], state: UInt64 = 9) -> Result<HTTPResponse, any Error> {
        let own = types.reduce(into: NativeMeetFixture.string(1, "spaces/demo/devices/one")
            + NativeMeetFixture.number(4, state)) {
                $0 += NativeMeetFixture.bytes(
                    41,
                    NativeMeetFixture.number(1, $1) + NativeMeetFixture.number(2, 1)
                )
            }
        let full = NativeMeetFixture.bytes(1, Data()) + NativeMeetFixture.bytes(2, own)
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full)))
    }

    private func device(state: UInt64, types: [UInt64], token: String) -> Result<HTTPResponse, any Error> {
        let data = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, state)
        let requirements = types.reduce(into: data) {
            $0 += NativeMeetFixture.bytes(
                41,
                NativeMeetFixture.number(1, $1) + NativeMeetFixture.number(2, 1)
            )
        }
        return NativeMeetFixture.ok(requirements, token: token)
    }
}
