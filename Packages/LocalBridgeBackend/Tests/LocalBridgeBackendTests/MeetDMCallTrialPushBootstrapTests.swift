import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

extension MeetDMCallTrialTests {
    private actor HoldPushPage: HTTPTransport {
        let base: ScriptedTransport
        private(set) var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ base: ScriptedTransport) {
            self.base = base
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let response = try await base.send(request)
            if request.traceLabel == "meet-push-bootstrap" {
                started = true
                await withCheckedContinuation { continuation = $0 }
            }
            return response
        }

        func release() {
            continuation?.resume(); continuation = nil
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStream {
            try await base.stream(request)
        }
    }

    private func pushPage() -> Result<HTTPResponse, any Error> {
        ScriptedTransport.ok(
            #"<script>window.WIZ_global_data={"qwAQke":"DynamiteWebUi","wU9aJb":"key-secret","#
                + #""pZ68sc":"project-secret","ttqQxf":"topic-secret","TyXQle":"1"};</script>"#
        )
    }

    @Test func missingMoleConfigurationReadsStandalonePageAndCachesTheCompleteResult() async throws {
        let transport = try ScriptedTransport(loadingResponses() + [pushPage()])
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        let incoming = try await trial.incomingCalls()
        await incoming.stop()
        _ = try await trial.incomingCalls()
        let sent = await transport.sent
        #expect(sent.count == 5)
        #expect(sent.last?.url.absoluteString == "https://chat.google.com/u/0/app/home")
        #expect(sent.last?.headers["Cookie"] == "SAPISID=cookie-sentinel")
        #expect(sent.allSatisfy { !$0.url.host!.contains("signaler") && !$0.url.path.contains("$rpc") })
        let report = await trial.report
        #expect(report.contains("Incoming watch config: standalone Chat shell accepted"))
        #expect(report.contains("Meet watch config wU9aJb: absent"))
        #expect(report.contains("Meet watch config wU9aJb: string, 10 bytes, valid"))
        #expect(!report.contains("secret"))
        await trial.close()
    }

    @Test func incompleteStandalonePageReportsShapesAndDoesNotCreateAWatch() async throws {
        let transport = try ScriptedTransport(loadingResponses() + [
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi"))
        ])
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        await #expect(throws: MeetDMCallTrialError.missingPushConfiguration) {
            try await trial.incomingCalls()
        }
        #expect(await transport.sent.count == 5)
        #expect(await trial.report.contains("Neither Chat page supplied supported Meet watch configuration"))
        await trial.close()
    }

    @Test func signedOutStandalonePageNeverBecomesWatchConfiguration() async throws {
        let transport = try ScriptedTransport(loadingResponses() + [
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "AccountsSignInUi"))
        ])
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        await #expect(throws: MeetPushBootstrapError.signedOut) { try await trial.incomingCalls() }
        #expect(await transport.sent.count == 5)
        await trial.close()
    }

    @Test func closedTrialCannotCacheOrDeliverDelayedStandaloneConfiguration() async throws {
        let base = try ScriptedTransport(loadingResponses() + [pushPage()])
        let transport = HoldPushPage(base)
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        let task = Task { try await trial.incomingCalls() }
        while await !(transport.started) {
            await Task.yield()
        }
        await trial.close()
        await transport.release()
        await #expect(throws: MeetDMCallTrialError.superseded) { try await task.value }
        await #expect(throws: MeetDMCallTrialError.noSession) { try await trial.incomingCalls() }
        #expect(await base.sent.count == 5)
    }
}

extension MeetDMCallTrialTests {
    @Test func fifteenByteOpaqueTopicCreatesIncomingTrialWithoutStandaloneFallback() async throws {
        let topic = "scope\u{0}topic\u{1F}xxx"
        #expect(topic.utf8.count == 15)
        let fields: [String: Any] = [
            "qwAQke": "DynamiteWebUi", "SMqcke": "xsrf-sentinel",
            "wU9aJb": "KEY", "pZ68sc": "PROJECT", "ttqQxf": topic
        ]
        let json = try JSONSerialization.data(withJSONObject: fields)
        var responses = try loadingResponses()
        responses[0] = ScriptedTransport.ok(
            "<script>window.WIZ_global_data=\(String(decoding: json, as: UTF8.self));</script>"
        )
        let transport = ScriptedTransport(responses)
        let (trial, _) = try await trial(transport)
        _ = try await trial.loadPeople()
        let incoming = try await trial.incomingCalls()
        #expect(await transport.sent.count == 4)
        #expect(await trial.report.contains("Meet watch config ttqQxf: string, 15 bytes, valid"))
        #expect(await !trial.report.contains(topic))
        await incoming.stop()
        await trial.close()
    }
}
