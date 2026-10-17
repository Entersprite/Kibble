import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct CallCleanupFeedbackTests {
    @Test(arguments: [false, true])
    func normalHangupReportsUnconfirmedLeaveWhileClosingLocalMedia(failsLeave: Bool) async throws {
        let helper = LocalBridgeAudioCallServiceTests()
        var responses = helper.nativeResponses(outgoing: true)
        if failsLeave {
            responses[responses.count - 1] = .success(HTTPResponse(
                status: 503, headers: HTTPHeaders([]), body: Data()
            ))
        }
        let setup = try await helper.setup(responses)
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.startOutgoing(to: helper.recipient(setup), callID: id)
        try await setup.service.hangUp(callID: id)
        #expect(setup.service.snapshot?.phase == .ended)
        #expect(setup.media.engines.first?.closed == true)
        if failsLeave {
            #expect(setup.service.snapshot?.failureMessage?.contains("this device left") == true)
        } else {
            #expect(setup.service.snapshot?.failureMessage == nil)
        }
        let sent = await setup.base.sent
        #expect(sent.filter { $0.url.path.hasSuffix("CancelMeetingInvite") }.count == 1)
        #expect(sent.filter { $0.url.path.hasSuffix("UpdateMeetingDevice") }.count == 2)
        await setup.service.stop()
    }

    @Test func cancellationFailureIsVisibleWithoutRetryingItsMutation() async throws {
        let helper = LocalBridgeAudioCallServiceTests()
        var responses = helper.nativeResponses(outgoing: true)
        responses[responses.count - 2] = .success(HTTPResponse(
            status: 500, headers: HTTPHeaders([]), body: Data()
        ))
        let setup = try await helper.setup(responses)
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.startOutgoing(to: helper.recipient(setup), callID: id)
        try await setup.service.hangUp(callID: id)
        #expect(setup.service.snapshot?.failureMessage?.contains("ringing was cancelled") == true)
        #expect(setup.media.engines.first?.closed == true)
        #expect(await setup.base.sent.filter { $0.url.path.hasSuffix("CancelMeetingInvite") }.count == 1)
        await setup.service.stop()
    }
}
