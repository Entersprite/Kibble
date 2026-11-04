import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MeetingLinkJoinTests {
    @Test(arguments: ["", "?authuser=2&utm_source=calendar&companion=1"])
    func joiningDuringAccountBootstrapWaitsAndUsesTheExistingMeetingWithoutInviting(
        _ query: String
    ) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(fixtures.nativeResponses(), hold: "*")
        let listening = Task { try await setup.service.startListening() }
        try await fixtures.waitForHold(setup)
        let id = UUID(), url = try #require(URL(string:
            "https://meet.google.com/meet/abc-defg-hij" + query
        ))
        let canonicalURL = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let joining = Task { try await setup.service.joinMeeting(at: url, callID: id) }
        #expect(await eventually { setup.service.conversationSnapshot?.id == id })
        #expect(setup.media.engines.isEmpty)
        await setup.transport.release()
        try await listening.value
        try await joining.value
        #expect(setup.media.engines.count == 1)
        #expect(setup.service.conversationSnapshot?.target.meetingURL == canonicalURL)
        let sent = await setup.base.sent
        let resolve = try #require(sent.first { $0.url.path.hasSuffix("ResolveMeetingSpace") })
        #expect(try resolve.body == (MeetCallWire.resolveOffered(code: "abc-defg-hij")))
        #expect(try resolve
            .headers["X-Goog-Meeting-Identifier"] == (MeetCallWire.offeredIdentifier(code: "abc-defg-hij")))
        #expect(!sent.contains { $0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(!sent.contains { $0.url.path.hasSuffix("CreateMeetingInvite") })
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test(arguments: [true, false])
    func endingAJoinDuringBootstrapDoesNotCancelTheSharedAccountSetup(_ meetingLink: Bool) async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(fixtures.nativeResponses(), hold: "*")
        let listening = Task { try await setup.service.startListening() }
        try await fixtures.waitForHold(setup)
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let joining = Task {
            if meetingLink {
                try await setup.service.joinMeeting(at: url, callID: id)
            } else {
                try await setup.service.joinConversationCall(to: .init(
                    conversationID: .init("space/test-group"), displayName: "Group"
                ), callID: id)
            }
        }
        #expect(await eventually { setup.service.conversationSnapshot?.id == id })
        try await setup.service.hangUp(callID: id)
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(setup.service.conversationSnapshot?.phase == .ended)
        #expect(setup.media.engines.isEmpty && !setup.service.hasLoadedPeople)
        await setup.transport.release()
        try await listening.value
        #expect(setup.service.hasLoadedPeople)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("ResolveMeetingSpace") })
        await setup.service.stop()
    }

    @Test func resolverRefusalRemainsInTheMatchingMeetingReportWithoutLeakingTheLink() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let refused = HTTPResponse(
            status: 403,
            headers: HTTPHeaders([]),
            body: Data("private-provider-url-and-token".utf8)
        )
        let setup = try await fixtures.setup([fixtures.nativeResponses()[0], .success(refused)])
        try await setup.service.startListening()
        let id = UUID(), url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        await #expect(throws: ChatError.self) { try await setup.service.joinMeeting(at: url, callID: id) }
        let report = try #require(await setup.service.diagnosticReport(callID: id))
        #expect(report.contains("ResolveMeetingSpace: public meeting link started"))
        #expect(report.contains("Meeting link preparation: HTTP 403"))
        #expect(!report.contains("abc-defg-hij") && !report.contains("private-provider-url-and-token"))
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.service.diagnosticReport(callID: UUID()) == nil)
        await setup.service.stop()
        #expect(await setup.service.diagnosticReport(callID: id) == nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}
