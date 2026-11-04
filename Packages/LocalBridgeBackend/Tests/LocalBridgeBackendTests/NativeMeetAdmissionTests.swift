import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetAdmissionTests {
    @Test func joiningAlongsideTheBrowserReachesConfirmedOutgoingAudio() async throws {
        let responses = NativeMeetFixture.responses(deviceTransfer: 3).map { result in
            result.map { HTTPResponse(
                status: $0.status,
                headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                    name: "X-Goog-Meeting-Debugid", value: "conference-sentinel"
                )]), body: $0.body
            ) }
        }
        let transport = ScriptedTransport(responses)
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(media.requests.count == 1)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("registered; join state=2; transfer=3; deleted=false"))
        #expect(report.contains("join confirmed; join state=1; transfer=0; deleted=false"))
        #expect(report.contains("upstream registration accepted"))
        await session.close()
        try await assertOnlyTheNativeDeviceWasChanged(transport)
    }

    @Test(arguments: [UInt64(3), 4, 9, 13, 14, 15, UInt64.max])
    func anUnconfirmedJoinReportsItsStateAndNeverRegistersAudio(_ state: UInt64) async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses(deviceTransfer: 3, joinedState: state))
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.connect() }
        #expect(media.closed && media.requests.isEmpty)
        let report = await session.takeReport().joined(separator: "\n")
        let expected = state <= 15 ? String(state) : "unknown"
        #expect(report
            .contains("join reply or failure; join state=" + expected + "; transfer=0; deleted=false"))
        #expect(report.contains("local media closed; device leave settled"))
        #expect(!report.contains("18446744073709551615"))
        #expect(!report.contains("spaces/demo"))
        await session.close()
        try await assertOnlyTheNativeDeviceWasChanged(transport)
    }

    private func assertOnlyTheNativeDeviceWasChanged(_ transport: ScriptedTransport) async throws {
        let sent = await transport.sent
        #expect(sent.count == 5 || sent.count == 6)
        #expect(!sent.contains { $0.url.path.contains("Invite") })
        for request in sent.filter({ $0.url.path.hasSuffix("UpdateMeetingDevice") }) {
            let body = try #require(request.body)
            let value = try #require(ProtoFieldScan.payloads(ofField: 1, in: body).first)
            #expect(ProtoFieldScan.payloads(ofField: 1, in: value) == [Data("spaces/demo/devices/one".utf8)])
            #expect(ProtoFieldScan.varintValues(ofField: 54, in: value).isEmpty)
        }
    }
}
