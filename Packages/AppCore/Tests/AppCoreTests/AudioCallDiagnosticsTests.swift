import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallDiagnosticsTests {
    @Test func preProviderRefusalIsReportedOnlyForItsCurrentCall() async throws {
        let me = Member.ID("self")
        let peer = Member(id: .init("peer"), kind: .human)
        let conversation = Conversation(id: .init("opaque"), kind: .directMessage, members: [me, peer.id])
        let service = RecordingAudioService(recipient: .init(
            conversationID: conversation.id, memberID: peer.id, displayName: "Private person"
        ))
        service.outgoingFailure = ServiceFailure.notAuthorized
        let calls = AudioCallController()
        calls.start(service: service)
        try await wait { calls.canCall(conversation: conversation, members: [peer], me: me) }
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        try await wait { calls.call?.phase == .failed }
        let report = try #require(calls.diagnosticReport(callID: id))
        #expect(report.contains("Call control failure: notAuthorized"))
        #expect(!report.contains("Private person"))
        #expect(calls.diagnosticReport(callID: UUID()) == nil)
        service.outgoingFailure = nil
        let replacement = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        #expect(calls.diagnosticReport(callID: id) == nil)
        #expect(calls.diagnosticReport(callID: replacement)?.contains("notAuthorized") == false)
        await calls.stop()
        #expect(calls.diagnosticReport(callID: replacement) == nil)
    }

    @Test func unknownWireCodesAndDetailsNeverEnterDiagnostics() {
        let error = ServiceFailure(code: "private-error-url", details: .string("private token"))
        #expect(CallOperationFailure(id: UUID(), error: error).code == "unclassified")
        let detailedKnown = ServiceFailure(code: "notAuthorized", details: .string("private token"))
        #expect(CallOperationFailure(id: UUID(), error: detailedKnown).code == "unclassified")
        #expect(CallOperationFailure(id: UUID(), error: ChatError.transport("private token")).code
            == "unclassified")
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition())
    }
}
