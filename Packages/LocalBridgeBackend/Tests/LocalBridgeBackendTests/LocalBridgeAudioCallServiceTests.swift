import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct LocalBridgeAudioCallServiceTests {
    struct Setup {
        let service: LocalBridgeAudioCallService
        let transport: CallServiceTransport
        let base: ScriptedTransport
        let media: MediaFactory
        let store: KeychainCredentialStore
    }

    func setup(
        _ responses: [Result<HTTPResponse, any Error>] = [], hold: String? = nil
    ) async throws -> Setup {
        let fixtures = MeetDMCallTrialTests()
        var loading = try fixtures.loadingResponses()
        var shell = try loading[0].get()
        let html = String(decoding: shell.body, as: UTF8.self).replacingOccurrences(
            of: "\"qwAQke\"",
            with: "\"wU9aJb\":\"KEY\",\"pZ68sc\":\"PROJECT\",\"ttqQxf\":\"TOPIC\",\"qwAQke\""
        )
        shell.body = Data(html.utf8)
        loading[0] = .success(shell)
        let base = ScriptedTransport(loading + responses)
        let transport = CallServiceTransport(base, hold: hold)
        let (trial, store) = try await fixtures.trial(transport)
        let media = MediaFactory()
        let service = LocalBridgeAudioCallService(trial: trial, mediaFactory: { media.make() })
        return Setup(service: service, transport: transport, base: base, media: media, store: store)
    }

    func nativeResponses(outgoing: Bool = false) -> [Result<HTTPResponse, any Error>] {
        [MeetDMCallTrialTests().preparingResponses()[0]]
            + NativeMeetFixture.responses(includeInvite: outgoing).map { value in
                value.map { response in
                    var response = response
                    response.headers = HTTPHeaders(fields: response.headers.fields + [.init(
                        name: "X-Goog-Meeting-Debugid", value: "conference-sentinel"
                    )])
                    return response
                }
            }
    }

    func recipient(_ setup: Setup) throws -> AudioCallRecipient {
        try LocalBridgeAudioCallService.recipient(#require(setup.service.people.values.first))
    }

    func waitForHold(_ setup: Setup) async throws {
        for _ in 0 ..< 10000 {
            if await setup.transport.started {
                return
            }
            await Task.yield()
        }
        try #require(await setup.transport.started)
    }

    func ring(_ setup: Setup, id: String = "ring-secret") async throws {
        let ring = NativeMeetFixture.string(1, id) + NativeMeetFixture.string(2, "abc-defg-hij")
            + NativeMeetFixture.number(4, 1) + NativeMeetFixture.string(8, "receiver-secret")
            + NativeMeetFixture.string(11, "dm/valid-dm") + NativeMeetFixture.number(12, 2)
            + NativeMeetFixture.string(7, "70;notification-token")
        let watcher = try #require(setup.service.incoming)
        for _ in 0 ..< 10000 {
            if await setup.transport.watched {
                break
            }
            await Task.yield()
        }
        let event = try MeetPushWire.payload(NativeMeetFixture.bytes(1, ring))
        guard case let .ring(value) = event else {
            throw MeetCallWire.WireError.malformedResponse
        }
        await watcher.handle(.notification(.ring(value)))
    }

    @Test func sessionListeningLoadsOnlySupportedDomainRecipientsWithoutMicrophone() async throws {
        let setup = try await setup()
        try await setup.service.startListening()
        let recipient = try recipient(setup)
        #expect(recipient.conversationID == .init("dm/valid-dm"))
        #expect(recipient.memberID == .init("alice-id"))
        #expect(recipient.displayName == "Alice Person")
        #expect(setup.media.engines.isEmpty)
        await setup.service.stop()
        #expect(setup.service.people.isEmpty)
    }

    @Test func outgoingRegistersThenInvitesMutesEndsAndRepeatsWithFreshMedia() async throws {
        let setup = try await setup(nativeResponses(outgoing: true) + nativeResponses(outgoing: true))
        try await setup.service.startListening()
        let recipient = try recipient(setup)
        for _ in 0 ..< 2 {
            let id = UUID()
            try await setup.service.startOutgoing(to: recipient, callID: id)
            #expect(setup.service.snapshot?.phase == .ringing)
            let engine = try #require(setup.media.engines.last)
            #expect(engine.requests.count == 1)
            try await ring(setup, id: "busy-" + id.uuidString)
            #expect(setup.service.snapshot?.id == id)
            try await setup.service.setMuted(true, callID: id)
            #expect(engine.isMicrophoneMuted)
            try await setup.service.setMuted(false, callID: id)
            #expect(!engine.isMicrophoneMuted)
            await #expect(throws: ChatError.self) {
                try await setup.service.startOutgoing(to: recipient, callID: UUID())
            }
            try await setup.service.hangUp(callID: id)
            #expect(engine.closed)
            #expect(engine.closeCount == 1)
            #expect(setup.service.snapshot?.phase == .ended)
        }
        #expect(setup.media.engines.count == 2)
        #expect(await setup.base.sent.filter { $0.url.path.hasSuffix("CreateMeetingInvite") }.count == 2)
        #expect(await setup.base.sent.filter { $0.url.path.hasSuffix("CancelMeetingInvite") }.count == 2)
        let report = await setup.service.report
        for value in ["cookie-sentinel", "conference-sentinel", "Alice Person", "alice-id"] {
            #expect(!report.contains(value))
        }
        await setup.service.stop()
    }

    @Test func incomingOpensWithNoMediaAndOnlyAcceptCreatesReceiverMedia() async throws {
        let setup = try await setup(nativeResponses())
        try await setup.service.startListening()
        try await ring(setup)
        let offered = try #require(setup.service.snapshot)
        #expect(offered.phase == .incoming)
        #expect(setup.media.engines.isEmpty)
        try await ring(setup, id: "additional-ring")
        #expect(setup.service.snapshot?.id == offered.id)
        try await setup.service.accept(callID: offered.id)
        #expect(setup.media.engines.count == 1)
        #expect(setup.service.snapshot?.phase == .connecting)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        try await setup.service.hangUp(callID: offered.id)
        #expect(setup.media.engines[0].closed)
        await setup.service.stop()
    }

    @Test func declinedAcknowledgesRequestWithoutClaimingCallerStoppedOrStartingMedia() async throws {
        let response = HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        let setup = try await setup([
            MeetDMCallTrialTests().preparingResponses()[0],
            .success(response),
            .success(response)
        ])
        try await setup.service.startListening()
        try await ring(setup)
        let id = try #require(setup.service.snapshot?.id)
        try await setup.service.decline(callID: id)
        #expect(setup.service.snapshot?.phase == .declined)
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.base.sent.filter { $0.url.path.hasSuffix("DeclineMeetingInvite") }.count == 1)
        #expect(await setup.service.report.contains("caller ringing termination is not confirmed"))
        await setup.service.stop()
    }
}

@MainActor
final class MediaFactory {
    var engines: [StreamFakeMedia] = []
    func make() -> any CallMediaEngine {
        let engine = StreamFakeMedia()
        engines.append(engine)
        return engine
    }
}

actor CallServiceTransport: HTTPTransport {
    let base: ScriptedTransport
    let hold: String?
    private(set) var started = false
    private(set) var watched = false
    private var pending: CheckedContinuation<Void, Never>?

    init(_ base: ScriptedTransport, hold: String?) {
        self.base = base
        self.hold = hold
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("chooseServer") {
            watched = true
            // Hold listening separately so a concurrent watch cannot consume
            // scripted call responses. Cancellation always releases the hold.
            while true {
                try await Task.sleep(for: .seconds(1))
            }
        }
        let response = try await base.send(request)
        if let hold, !started, hold == "*" || request.url.path.hasSuffix(hold) {
            started = true
            await withCheckedContinuation { pending = $0 }
        }
        return response
    }

    func release() {
        pending?.resume()
        pending = nil
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}
