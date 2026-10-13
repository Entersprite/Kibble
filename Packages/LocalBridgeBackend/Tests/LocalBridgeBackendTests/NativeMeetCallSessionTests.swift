import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetCallSessionTests {
    @Test func joinedNativePeerRingsOnlyExplicitlyAndLeavesWithTheJoinedToken() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses(includeInvite: true))
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(await transport.sent.count == 4)
        #expect(media.calls == ["offer", "answer", "connected"])
        try await session.invite(callee: "synthetic-peer")
        await session.close()
        #expect(media.calls.last == "close")
        let sent = await transport.sent
        #expect(sent.count == 7)
        #expect(sent[1].url.path.hasSuffix("CreateMediaSession"))
        #expect(sent[1].headers["x-goog-meeting-token"] == nil)
        let body = try #require(sent[1].body)
        let wireSession = try #require(ProtoFieldScan.payloads(ofField: 1, in: body).first)
        let config = try #require(ProtoFieldScan.payloads(ofField: 3, in: wireSession).first)
        let dtls = try #require(ProtoFieldScan.payloads(ofField: 1, in: config).first)
        #expect(ProtoFieldScan.varintValues(ofField: 3, in: dtls) == [3])
        #expect(!ProtoFieldScan.fields(in: config).fields.contains { $0.number == 44 })
        let collections = try #require(ProtoFieldScan.payloads(ofField: 8, in: config).first)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: collections) == [1])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: collections) == [1])
        #expect(sent[4].url.path.hasSuffix("CreateMeetingInvite"))
        #expect(sent[4].headers["x-goog-meeting-token"] == "30;joined")
        #expect(sent[5].url.path.hasSuffix("CancelMeetingInvite"))
        #expect(sent[5].headers["x-goog-meeting-token"] == "30;joined")
        #expect(sent[6].headers["x-goog-meeting-token"] == "35;cancelled")
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("audio output enabled; SRTP AEAD_AES_256_GCM"))
        for secret in [
            "nativepassword", String(repeating: "R", count: 27) + "=", "synthetic-peer", "cookie-sentinel",
            "30;joined", String(repeating: "U", count: 27) + "="
        ] {
            #expect(!report.contains(secret))
        }
    }

    @Test func mediaFailureAfterRegistrationLeavesAndCannotRing() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses(join: false))
        let media = NativeFakeMedia(failConnection: true)
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: CallMediaError.timedOut) { try await session.connect() }
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(callee: "synthetic-peer")
        }
        #expect(media.calls.last == "close")
        let sent = await transport.sent
        #expect(sent.count == 4)
        #expect(sent[3].url.path.hasSuffix("UpdateMeetingDevice"))
        #expect(await session.takeReport()
            .contains("Native cleanup: local media closed; device leave settled"))
    }

    @Test func losingTheControlTransportAfterJoiningStopsAnInvitation() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        media.isConnected = false
        await #expect(throws: MeetDeviceSessionError.mediaNotConnected) {
            try await session.invite(callee: "synthetic-peer")
        }
        #expect(await transport.sent.count == 4)
        await session.close()
        #expect(await transport.sent.count == 5)
    }

    @Test func mediaRefusalClosesLocallyWithoutRegistrationInvitationOrRetry() async throws {
        var responses = Array(NativeMeetFixture.responses().prefix(2))
        responses[1] = .success(HTTPResponse(
            status: 400, headers: HTTPHeaders([]), body: Data([0x08, 0x03])
        ))
        let transport = ScriptedTransport(responses)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetCallClientError.self) { try await session.connect() }
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(callee: "synthetic-peer")
        }
        await #expect(throws: MeetDeviceSessionError.closed) { try await session.connect() }
        await session.close()
        #expect(media.calls.allSatisfy { $0 == "offer" || $0 == "close" })
        #expect(media.calls.last == "close")
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent[1].url.path.hasSuffix("CreateMediaSession"))
        let report = await session.takeReport()
        #expect(report.contains("Meet error message diagnostic: absent (raw message withheld)"))
        #expect(report.contains("Native join: HTTP 400; error body protobuf; code 3"))
        #expect(report.contains(
            "Native cleanup: local media closed; caller device registration was not attempted"
        ))
        #expect(!report.contains("Native cleanup: local media closed; device leave settled"))
    }

    @Test func answerFailureReportsOnlyItsFixedStageAndStopsBeforeRegistration() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses(invalidMediaAnswer: true))
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetAudioOffer.AnswerFailure.dtls) { try await session.connect() }
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(callee: "synthetic-peer")
        }
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("Meet media answer was invalid at DTLS fingerprint or role."))
        #expect(report.contains("caller device registration was not attempted"))
        #expect(!report.contains("mediasessions/native"))
        #expect(await transport.sent.count == 2)
        #expect(media.calls == ["offer", "close"])
    }

    @Test func iceFailureIncludesShapesWithoutCredentialsOrRegistration() async throws {
        let secret = "private:ufrag!sentinel"
        let transport = ScriptedTransport(NativeMeetFixture.responses(ufrag: secret))
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: MeetAudioOffer.AnswerFailure.ice) { try await session.connect() }
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("Native ICE ufrag:"))
        #expect(report.contains("alphabet other ASCII; padding none; supported no"))
        #expect(report
            .contains("Native ICE password: bytes 28; alphabet Base64; padding terminal 1; supported yes"))
        #expect(!report.contains(secret))
        #expect(!report.contains(String(repeating: "R", count: 27) + "="))
        #expect(report.contains("caller device registration was not attempted"))
        #expect(await transport.sent.count == 2)
        #expect(media.calls == ["offer", "close"])
    }

    @Test func closeWaitsForLateRegistrationAndThenLeavesWithoutJoiningOrRinging() async throws {
        let base = ScriptedTransport(NativeMeetFixture.responses(join: false))
        let transport = NativeHoldRegistration(base)
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        let join = Task { try await session.connect() }
        while await !(transport.started) {
            await Task.yield()
        }
        let close = Task { await session.close() }
        while media.calls.last != "close" {
            await Task.yield()
        }
        await transport.release()
        await close.value
        await #expect(throws: CancellationError.self) { try await join.value }
        #expect(await base.sent.count == 4)
        #expect(!media.calls.contains("connected"))
    }

    @Test func hangupDuringAnInviteSettlesItBeforeLeavingTheDevice() async throws {
        let base = ScriptedTransport(NativeMeetFixture.responses(includeInvite: true))
        let transport = NativeHoldRegistration(base, method: "CreateMeetingInvite")
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        let ring = Task { try await session.invite(callee: "synthetic-peer") }
        while await !(transport.started) {
            await Task.yield()
        }
        let close = Task { await session.close() }
        while media.calls.last != "close" {
            await Task.yield()
        }
        #expect(await base.sent.count == 5)
        await transport.release()
        await close.value
        await #expect(throws: CancellationError.self) { try await ring.value }
        #expect(await base.sent.count == 7)
        #expect(await session.takeReport()
            .contains("Native cleanup: local media closed; device leave settled"))
    }

    @Test func accountReplacementAfterRegistrationCleansUpAndStopsJoin() async throws {
        let base = ScriptedTransport(NativeMeetFixture.responses(join: false))
        let transport = NativeHoldRegistration(base)
        let account = NativeAccountGate()
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia(), validate: {
            try await account.validate()
        })
        let join = Task { try await session.connect() }
        while await !(transport.started) {
            await Task.yield()
        }
        await account.replace()
        await transport.release()
        await #expect(throws: MeetDMCallTrialError.accountChanged) { try await join.value }
        #expect(await base.sent.count == 4)
    }
}

@MainActor
final class NativeFakeMedia: CallMediaEngine {
    var isConnected = false
    var calls: [String] = []
    var answer: String?
    var eventHandler: (@Sendable (CallMediaEvent) async -> Void)?
    let failConnection: Bool

    init(failConnection: Bool = false) {
        self.failConnection = failConnection
    }

    func makeAudioOffer(serverControlChannel: String?) async throws -> CallAudioOffer {
        #expect(serverControlChannel == "collections")
        calls.append("offer")
        return CallAudioOffer(sdp: NativeMeetFixture.offer, srtpProfile: .aeadAES256GCM)
    }

    func applyAnswer(_ sdp: String) async throws {
        #expect(sdp.contains("a=setup:passive"))
        #expect(sdp.contains("a=group:BUNDLE 0 1"))
        #expect(sdp.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
        answer = sdp
        calls.append("answer")
    }

    func waitUntilConnected(timeout _: Duration) async throws {
        if failConnection {
            throw CallMediaError.timedOut
        }
        calls.append("connected")
        isConnected = true
    }

    func setEventHandler(_ handler: (@Sendable (CallMediaEvent) async -> Void)?) {
        eventHandler = handler
    }

    func setMuted(_: Bool) {}
    func close() {
        calls.append("close"); isConnected = false
    }
}

private actor NativeAccountGate {
    var changed = false
    func replace() {
        changed = true
    }

    func validate() throws {
        if changed {
            throw MeetDMCallTrialError.accountChanged
        }
    }
}

private actor NativeHoldRegistration: HTTPTransport {
    let base: ScriptedTransport
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let method: String

    init(_ base: ScriptedTransport, method: String = "CreateMeetingDevice") {
        self.base = base
        self.method = method
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await base.send(request)
        if request.url.path.hasSuffix(method) {
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
