import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetMicrophoneTests {
    @Test func returnedStreamInheritsCurrentCallContextWithoutChangingLaterWrites() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        media.omitParentContext = true
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(try await session.setMuted(true))
        #expect(try await session.setMuted(false))
        #expect(media.requests.count == 3)
        #expect(await transport.sent.count == 4)
        let registered = try stream(in: media.requests[0], variant: 4)
        for request in media.requests.dropFirst() {
            let modified = try stream(in: request, variant: 2)
            for field in [3, 5] {
                #expect(ProtoFieldScan.payloads(ofField: field, in: registered)
                    == ProtoFieldScan.payloads(ofField: field, in: modified))
                #expect(ProtoFieldScan.payloads(ofField: field, in: modified).count == 1)
            }
        }
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("session inherited from current call"))
        #expect(report.contains("conference inherited from current call"))
        #expect(report.contains("initial microphone state confirmed"))
        #expect(report.contains("provider mute confirmed"))
        #expect(!report.contains("sentinel"))
        #expect(!report.contains("4242"))
        await session.close()
    }

    @Test func statusOnlyRegistrationAndMuteAcknowledgementsKeepCallUsable() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        media.omitEcho = true
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(try await session.setMuted(true))
        #expect(media.isMicrophoneMuted)
        #expect(try await session.setMuted(false))
        #expect(!media.isMicrophoneMuted)
        #expect(media.requests.count == 3)
        #expect(await transport.sent.count == 4)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("initial microphone announcement acknowledged"))
        #expect(report.contains("provider mute acknowledged; stream state not echoed"))
        #expect(report.contains("provider unmute acknowledged; stream state not echoed"))
        #expect(!report.contains("state confirmed"))
        await session.close()
    }

    @Test func registersOwnSSRCBeforeRingAndConfirmsMuteUnmute() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        #expect(media.requests.count == 1)
        let add = try stream(in: media.requests[0], variant: 4)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: add) == [2])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: add) == [1])
        let source = try #require(ProtoFieldScan.payloads(ofField: 8, in: add).first)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: source) == [Data([0x92, 0x21])])
        #expect(try flag(add) == 0)
        #expect(try await session.setMuted(true))
        #expect(media.isMicrophoneMuted)
        #expect(try await session.setMuted(false))
        #expect(!media.isMicrophoneMuted)
        #expect(media.requests.count == 3)
        #expect(try flag(stream(in: media.requests[1], variant: 2)) == 1)
        #expect(try flag(stream(in: media.requests[2], variant: 2)) == 0)
        #expect(await transport.sent.count == 4) // No automatic invitations.
        let request = try #require(await transport.sent[1].body)
        let requestSession = try #require(ProtoFieldScan.payloads(ofField: 1, in: request).first)
        let config = try #require(ProtoFieldScan.payloads(ofField: 3, in: requestSession).first)
        #expect(ProtoFieldScan.payloads(ofField: 17, in: config).count == 1)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("upstream registration accepted"))
        #expect(report
            .contains("registration checks: request matches; direction matches; media kind matches"))
        #expect(report
            .contains("session matches; stream matches; conference matches; mute matches; SSRC matches"))
        #expect(report.contains("provider mute confirmed"))
        #expect(report.contains("provider unmute confirmed"))
        for secret in [
            "track-sentinel",
            "stream-sentinel",
            "conference-sentinel",
            "cookie-sentinel",
            "4242"
        ] {
            #expect(!report.contains(secret))
        }
        await session.close()
    }

    @Test func failedRegistrationClosesAudioAndCannotInvite() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        media.failRegistration = true
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: CallMediaError.outgoingAudioUnconfirmed) { try await session.connect() }
        #expect(media.closed)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.invite(callee: "peer") }
        #expect(media.requests.count == 1)
        #expect(await session.audioStream == nil)
        #expect(await session.takeReport().contains { $0.contains("registration unconfirmed") })
        await session.close()
    }

    @Test func noConferenceContextDoesNotSubstituteLocalDebugID() async throws {
        let transport = ScriptedTransport(NativeMeetFixture.responses())
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        await #expect(throws: CallMediaError.outgoingAudioUnconfirmed) { try await session.connect() }
        #expect(media.requests.isEmpty)
        #expect(await session.takeReport().contains { $0.contains("conference context missing") })
        await session.close()
    }

    @Test func refusedMuteDoesNotClaimProviderConfirmation() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        media.failMute = true
        #expect(try await session.setMuted(true) == false)
        #expect(media.isMicrophoneMuted)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(report.contains("provider state unconfirmed"))
        #expect(!report.contains("provider mute confirmed"))
        await session.close()
    }

    @Test func closureRejectsLateMuteReplyAndNeverAffectsReplacementEngine() async throws {
        let transport = ScriptedTransport(responses())
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        media.holdMute = true
        let mute = Task { try await session.setMuted(true) }
        try await waitForReply(media)
        let closing = Task { await session.close() }
        for _ in 0 ..< 100 where !media.closed {
            await Task.yield()
        }
        #expect(media.closed)
        media.resume()
        _ = try await mute.value
        await closing.value
        #expect(await session.audioStream == nil)
        let report = await session.takeReport().joined(separator: "\n")
        #expect(!report.contains("provider mute confirmed"))
        await #expect(throws: MeetDeviceSessionError.closed) { try await session.setMuted(false) }
    }

    @Test func rapidToggleKeepsLatestLocalAndProviderState() async throws {
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        media.holdMute = true
        let first = Task { try await session.setMuted(true) }
        try await waitForReply(media)
        let latest = Task { try await session.setMuted(false) }
        for _ in 0 ..< 100 where media.isMicrophoneMuted {
            await Task.yield()
        }
        #expect(!media.isMicrophoneMuted)
        media.holdMute = false
        media.resume()
        #expect(try await !(first.value))
        #expect(try await latest.value)
        #expect(try flag(stream(in: #require(media.requests.last), variant: 2)) == 0)
        await session.close()
    }

    @Test func accountReplacementStopsMuteBeforeAnyPacket() async throws {
        let account = StreamAccount()
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(
            ScriptedTransport(responses()), media: media, validate: { try await account.validate() }
        )
        try await session.connect()
        await account.replace()
        await #expect(throws: MeetDMCallTrialError.accountChanged) { try await session.setMuted(true) }
        #expect(media.requests.count == 1)
        #expect(!media.isMicrophoneMuted)
        await session.close()
    }

    @Test func outOfOrderOwnerActionsCannotOverwriteTheLatestState() async throws {
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        #expect(try await session.setMuted(true, sequence: 2))
        #expect(try await session.setMuted(false, sequence: 1) == false)
        #expect(media.isMicrophoneMuted)
        #expect(media.requests.count == 2)
        await session.close()
    }

    @Test func stalePublicScopeCannotMuteAReplacementCall() async throws {
        let media = StreamFakeMedia()
        let session = try await NativeMeetFixture.session(ScriptedTransport(responses()), media: media)
        try await session.connect()
        let trial = MeetDMCallTrial()
        let scope = UUID()
        await trial.installMicrophoneFixture(session, scope: scope)
        await #expect(throws: MeetDMCallTrialError.superseded) {
            try await trial.setNativeMuted(true, scope: UUID(), sequence: 1)
        }
        #expect(!media.isMicrophoneMuted)
        #expect(media.requests.count == 1)
        #expect(try await trial.setNativeMuted(true, scope: scope, sequence: 1))
        #expect(media.isMicrophoneMuted)
        await trial.endNativeCall()
    }

    private func responses() -> [Result<HTTPResponse, any Error>] {
        NativeMeetFixture.responses().map { value in
            value.map { HTTPResponse(
                status: $0.status,
                headers: HTTPHeaders(fields: $0.headers.fields + [.init(
                    name: "X-Goog-Meeting-Debugid",
                    value: "conference-sentinel"
                )]),
                body: $0.body
            ) }
        }
    }

    private func stream(in request: Data, variant: Int) throws -> Data {
        let body = try #require(ProtoFieldScan.payloads(ofField: variant, in: request).first)
        return try #require(ProtoFieldScan.payloads(ofField: 4, in: body).first)
    }

    private func flag(_ stream: Data) throws -> UInt64 {
        let state = try #require(ProtoFieldScan.payloads(ofField: 10, in: stream).first)
        return try #require(ProtoFieldScan.varintValues(ofField: 1, in: state).first)
    }

    private func waitForReply(_ media: StreamFakeMedia) async throws {
        for _ in 0 ..< 1000 {
            if media.pending != nil {
                return
            }
            await Task.yield()
        }
        _ = try #require(media.pending)
    }
}

private extension MeetDMCallTrial {
    func installMicrophoneFixture(_ session: NativeMeetCallSession, scope: UUID) {
        native = session
        nativeScope = scope
    }
}

@MainActor
private final class StreamFakeMedia: CallMediaEngine {
    var isConnected = false
    var isMicrophoneMuted = false
    var supportsStreamControl: Bool {
        true
    }

    var requests: [Data] = []
    var failRegistration = false
    var omitEcho = false
    var omitParentContext = false
    var failMute = false
    var holdMute = false
    var closed = false
    var pending: CheckedContinuation<Void, Never>?

    func makeAudioOffer(serverControlChannel _: String?) async throws -> CallAudioOffer {
        let sdp = NativeMeetFixture.offer.replacingOccurrences(
            of: "a=mid:0\r\n",
            with:
            "a=mid:0\r\na=msid:stream-sentinel track-sentinel\r\na=ssrc:4242 cname:synthetic\r\n"
        )
        return CallAudioOffer(sdp: sdp, srtpProfile: .aeadAES256GCM)
    }

    func applyAnswer(_: String) async throws {}
    func waitUntilConnected(timeout _: Duration) async throws {
        isConnected = true
    }

    func setMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    func close() {
        closed = true; isConnected = false
    }

    func resume() {
        pending?.resume(); pending = nil
    }

    func exchangeStreamControl(
        _ request: Data, matches: @escaping @Sendable (Data) -> Bool, timeout _: Duration
    ) async throws -> Data {
        requests.append(request)
        let id = try #require(ProtoFieldScan.varintValues(ofField: 1, in: request).first)
        let registering = !ProtoFieldScan.payloads(ofField: 4, in: request).isEmpty
        if !registering, holdMute {
            await withCheckedContinuation { pending = $0 }
        }
        if closed {
            throw CallMediaError.closed
        }
        let operation = try #require(ProtoFieldScan.payloads(ofField: registering ? 4 : 2, in: request).first)
        var stream = try #require(ProtoFieldScan.payloads(ofField: 4, in: operation).first)
        if omitParentContext {
            var sparse = NativeMeetFixture.number(1, 2) + NativeMeetFixture.number(2, 1)
            for field in [4, 8, 10] {
                for payload in ProtoFieldScan.payloads(ofField: field, in: stream) {
                    sparse += NativeMeetFixture.bytes(UInt64(field), payload)
                }
            }
            stream = sparse
        }
        let header = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 1))
        let status = registering ? failRegistration : failMute
        let reply = NativeMeetFixture.number(1, id) + NativeMeetFixture.bytes(
            4,
            status ? NativeMeetFixture.number(1, 3) : Data()
        )
            + NativeMeetFixture.bytes(
                registering ? 5 : 2, header + (omitEcho ? Data() : NativeMeetFixture.bytes(4, stream))
            )
        #expect(matches(reply))
        return reply
    }
}

private actor StreamAccount {
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
