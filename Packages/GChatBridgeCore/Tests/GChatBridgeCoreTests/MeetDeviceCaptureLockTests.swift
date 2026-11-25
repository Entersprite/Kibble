import Foundation
import Testing
@testable import GChatBridgeCore

extension MeetDeviceSessionTests {
    @Test(arguments: [403, 401])
    func captureLockRegistrationRefusalSettlesOnlyAtTheExpectedHTTPStatus(_ status: Int) async throws {
        let refusal = MeetProto.number(1, 7) + MeetProto.string(2, "Unsupported audio/video lock")
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: status, headers: HTTPHeaders([]), body: base64(refusal))
        ])
        let session = try makeSession(transport)
        if status == 403 {
            await #expect(throws: MeetDeviceSessionError.captureLockUnsupported) {
                try await session.register(mediaSession: "mediasessions/native")
            }
        } else {
            await #expect(throws: MeetCallClientError.self) {
                try await session.register(mediaSession: "mediasessions/native")
            }
        }
        await #expect(throws: MeetDeviceSessionError.deviceExists) {
            try await session.register(mediaSession: "mediasessions/native")
        }
        if status == 403 {
            try await session.leave()
        } else {
            await #expect(throws: MeetDeviceSessionError.leaveUnconfirmed) { try await session.leave() }
        }
        #expect(await transport.sent.map(\.url.lastPathComponent) == ["CreateMeetingDevice"])
    }
}
