import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetIncomingWatchTests {
    private actor Events {
        private(set) var rings = 0
        private(set) var started = 0
        private(set) var diagnostics: [String] = []
        private(set) var messages: [String] = []
        private(set) var opened = false
        func record(_ event: MeetIncomingWatch.Event) {
            switch event {
            case .opened: opened = true
            case let .diagnostic(message): diagnostics.append(message)
            case .notification(.started): started += 1
            case .notification(.ring): rings += 1
            case let .failed(message): messages.append(message)
            default: break
            }
        }
    }

    private actor Validation {
        var count = 0
        let failsAt: Int
        init(_ failsAt: Int) {
            self.failsAt = failsAt
        }

        func check() throws {
            count += 1
            if count >= failsAt {
                throw MeetDMCallTrialError.accountChanged
            }
        }
    }

    private var chosen: Result<HTTPResponse, any Error> {
        ScriptedTransport.ok(#"["session-secret",1]"#)
    }

    private let initial = #"[[0,["c","sid-secret","",8,15,30000]]]"#

    private func frame(_ value: String) -> String {
        "\(value.utf8.count)\n\(value)"
    }

    private func notification(aid: Int) throws -> String {
        var ring = Data([0x0A, 0x04]) + Data("ring".utf8)
        ring += Data([0x12, 0x0C]) + Data("abc-defg-hij".utf8)
        ring += Data([0x20, 1, 0x5A, 0x05]) + Data("known".utf8) + Data([0x60, 1])
        let binary = Data([0x0A, UInt8(ring.count)]) + ring
        let change: PBLiteValue = [nil, .string(binary.base64EncodedString()), "42", nil, nil, [[["object"]]]]
        let response: PBLiteValue = [[["1", [nil, [[change]]]]]]
        let data: PBLiteValue = [response]
        let channel: PBLiteValue = [[.number(.integer(Int64(aid))), data]]
        return try channel.jsonString()
    }

    private func run(
        _ transport: any HTTPTransport, events: Events,
        validate: @escaping @Sendable () async throws -> Void = {},
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws {
        let config = try #require(MeetPushConfiguration(
            key: "key-secret",
            project: "project",
            topic: "topic-secret"
        ))
        let credentials = SessionCredentials(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "cookie-secret", domain: ".google.com", path: "/")
        ])!)
        await MeetIncomingWatch.run(
            requests: PunctualRequests(meet: config, endpoints: ChatEndpoints()), topic: .meetRings(config),
            client: PunctualClient(
                transport: transport,
                credentials: credentials,
                authorization: { _, _ in "proof-secret" }
            ),
            settings: .init(sleep: sleep, zx: { "zx" }), validate: validate,
            receive: { await events.record($0) }
        )
    }

    @Test func openingBodyEventsAreDeliveredAndPollAcknowledgesThem() async throws {
        let opened = try frame(initial) + frame(notification(aid: 1))
        let transport = ScriptedTransport(
            [chosen, ScriptedTransport.ok(opened)],
            streams: [.init(chunks: [frame(#"[[2,["stop"]]]"#)])]
        )
        let events = Events()
        try await run(transport, events: events)
        #expect(await events.opened)
        #expect(await events.rings == 1)
        let sent = await transport.sent
        #expect(sent.count == 3)
        #expect(sent[2].url.query?.contains("AID=1") == true)
        #expect(sent.allSatisfy { !$0.followsRedirects && $0.maxBodyBytes == 1_000_000 })
        #expect(sent.allSatisfy { $0.headers["Authorization"] == "proof-secret" })
    }

    @Test func headerOnlyHandshakeReadsSplitFramesAndSkipsRepeatedAid() async throws {
        let open = HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("x-http-initial-response", initial)]),
            body: Data()
        )
        let payload = try frame(notification(aid: 2))
        let split = payload.index(payload.startIndex, offsetBy: 11)
        let transport = ScriptedTransport([chosen, .success(open)], streams: [
            .init(chunks: [
                String(payload[..<split]),
                String(payload[split...]),
                payload,
                frame(#"[[3,["close"]]]"#)
            ])
        ])
        let events = Events()
        try await run(transport, events: events)
        #expect(await events.rings == 1)
        #expect(await events.messages.last == "Meet watch was closed by the server. Restart listening.")
    }

    @Test func accountChangeAfterOpenPreventsDeliveryAndPolling() async throws {
        let validation = Validation(3)
        let transport = try ScriptedTransport([
            chosen,
            ScriptedTransport.ok(frame(initial) + frame(notification(aid: 1)))
        ])
        let events = Events()
        try await run(transport, events: events, validate: { try await validation.check() })
        #expect(await transport.sent.count == 2)
        #expect(await events.rings == 0)
        #expect(await events.messages == ["The Chat account changed. Reload people."])
    }

    @Test func failedChooseNeverOpensAChannelAndWithholdsBodySecrets() async throws {
        let transport = ScriptedTransport([.success(HTTPResponse(
            status: 403, headers: HTTPHeaders([]), body: Data("private-refusal-secret".utf8)
        ))])
        let events = Events()
        try await run(transport, events: events)
        #expect(await transport.sent.count == 1)
        #expect(await events.messages == ["Meet watch returned HTTP 403."])
    }

    @Test func partialFrameFailureDoesNotDeliverAPartialRing() async throws {
        let transport = ScriptedTransport(
            [chosen, ScriptedTransport.ok(initial)],
            streams: [.init(chunks: ["999\n["])]
        )
        let events = Events()
        try await run(transport, events: events)
        #expect(await events.rings == 0)
        #expect(await events.messages == ["Meet watch response framing was invalid."])
    }

    @Test func cancellationDuringIdleSleepPreventsAnotherPoll() async throws {
        let transport = ScriptedTransport(
            [chosen, ScriptedTransport.ok(initial)],
            streams: [.init(chunks: [])]
        )
        let events = Events()
        let task = Task {
            try await run(transport, events: events, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        }
        while await transport.sent.count < 3 {
            await Task.yield()
        }
        task.cancel()
        try await task.value
        #expect(await transport.sent.count == 3)
        #expect(await events.messages.isEmpty)
    }
}

extension MeetIncomingWatchTests {
    @Test func wrappedSubscriptionAcknowledgementAndRingReachTheReceiverFromPoll() async throws {
        let watch: PBLiteValue = ["1", [["42"]]]
        let response: PBLiteValue = [[watch], nil, ["channel-secret"]]
        let channel: PBLiteValue = [[1, [response]]]
        let ack = try channel.jsonString()
        let transport = try ScriptedTransport([chosen, ScriptedTransport.ok(initial)], streams: [
            .init(chunks: [frame(ack), frame(notification(aid: 2)), frame(#"[[3,["stop"]]]"#)])
        ])
        let events = Events()
        try await run(transport, events: events)
        #expect(await events.started == 1)
        #expect(await events.rings == 1)
        let diagnostics = await events.diagnostics.joined(separator: "\n")
        #expect(diagnostics.contains("Meet watch: poll HTTP 200"))
        #expect(diagnostics.contains("watch responses 1; matching sequence 1; decoded 1 events"))
        #expect(!diagnostics.contains("secret"))
        #expect(!diagnostics.contains("abc-defg-hij"))
    }
}

extension MeetIncomingWatchTests {
    @Test func lostConnectionReopensWithAFreshChannelInsteadOfReusingTheDeadSubscription() async throws {
        let transport = try ScriptedTransport([
            chosen, ScriptedTransport.ok(initial), chosen,
            ScriptedTransport.ok(initial.replacingOccurrences(of: "sid-secret", with: "new-sid-secret"))
        ], streams: [
            .init(chunks: [], failure: ClassifiedTransportFailure(.connectionLost)),
            .init(chunks: [frame(notification(aid: 1)), frame(#"[[2,["stop"]]]"#)])
        ])
        let events = Events()
        try await run(transport, events: events)
        #expect(await transport.sent.count == 3)
        #expect(await events.messages.count == 1)
        try await run(transport, events: events)
        let sent = await transport.sent
        #expect(sent.count == 6)
        #expect(sent.last?.url.query?.contains("SID=new-sid-secret") == true)
        #expect(await events.rings == 1)
    }

    @Test func healthyPollTimeoutKeepsTheSameSubscription() async throws {
        let transport = ScriptedTransport([chosen, ScriptedTransport.ok(initial)], streams: [
            .init(chunks: [], failure: ClassifiedTransportFailure(.timedOut)),
            .init(chunks: [frame(#"[[1,["stop"]]]"#)])
        ])
        let events = Events()
        try await run(transport, events: events)
        let sent = await transport.sent
        #expect(sent.count == 4)
        #expect(sent[2].url.query?.contains("SID=sid-secret") == true)
        #expect(sent[3].url.query?.contains("SID=sid-secret") == true)
    }
}
