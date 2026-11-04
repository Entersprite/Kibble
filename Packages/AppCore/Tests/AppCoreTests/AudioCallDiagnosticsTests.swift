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

    @Test func knownProviderCategoriesAreUsefulWithoutExportingDetailsOrFutureNames() {
        let error = ServiceFailure(code: "providerFailure", details: .object([
            "type": .string("unsupported"), "capability": .string("https://secret.example/token")
        ]))
        let failure = CallOperationFailure(id: UUID(), error: error)
        #expect(failure.code == "providerFailure" && failure.providerCategory == "unsupported")
        let future = CallOperationFailure(id: UUID(), error: ServiceFailure(
            code: "providerFailure",
            details: .object([
                "type": .string("private-future-kind"),
                "message": .string("secret")
            ])
        ))
        #expect(future.code == "providerFailure" && future.providerCategory == nil)
    }

    @Test(arguments: ["meetingLinkEnvelope", "meetingLinkNormalization"])
    func onlyKnownCallStagesAreAccepted(_ stage: String) {
        let failure = CallOperationFailure(id: UUID(), error: ServiceFailure(
            code: "invalidRequest", details: .object([
                "callStage": .string(stage), "private": .string("private secret")
            ])
        ))
        #expect(failure.code == "invalidRequest" && failure.stage == stage)
        let unknown = CallOperationFailure(id: UUID(), error: ServiceFailure(
            code: "invalidRequest", details: .object(["callStage": .string("private secret")])
        ))
        #expect(unknown.code == "unclassified" && unknown.stage == nil)
    }

    @Test func linkShapeReportsStructureWithoutLinkContents() throws {
        let url = try #require(URL(string:
            "https://private-user:private-password@private-host.test:444/private-path/abcd-efgh-ijkl/"
                + "?private-query=private-value#private-fragment"
        ))
        let report = MeetingLinkDiagnosticShape.lines(url, supportedHosts: []).joined(separator: "\n")
        #expect(report.contains("advertised host=false; credentials=true; port=other"))
        #expect(report.contains("segments=2; lengths=12,14; trailing slash=true"))
        #expect(report.contains("groups=4,4,4; lowercase ASCII=true"))
        #expect(report.contains("query=true; fragment=true"))
        #expect(!report.contains("private") && !report.contains("abcd"))
        let huge = try #require(URL(string: "https://private-host.test/" + String(
            repeating: "a",
            count: 3000
        )))
        #expect(MeetingLinkDiagnosticShape
            .lines(huge, supportedHosts: []) == ["Meeting link shape: over size limit"])
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
