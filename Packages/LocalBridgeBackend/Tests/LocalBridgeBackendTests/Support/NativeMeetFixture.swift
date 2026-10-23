import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

enum NativeMeetFixture {
    static let digest = Array(repeating: "AA", count: 32).joined(separator: ":")
    static var offer: String {
        [
            "v=0", "a=group:BUNDLE 0 1", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0", "a=sendrecv",
            "a=ice-ufrag:test", "a=ice-pwd:nativepassword1234567890",
            "a=fingerprint:sha-256 " + digest, "a=setup:actpass", "a=rtpmap:111 opus/48000/2",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:1", "a=sctp-port:5000",
            "a=ice-ufrag:test", "a=ice-pwd:nativepassword1234567890",
            "a=fingerprint:sha-256 " + digest, "a=setup:actpass"
        ].joined(separator: "\r\n") + "\r\n"
    }

    static func session(
        _ transport: any HTTPTransport, media: any CallMediaEngine,
        staysWhenAlone: Bool = false,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> NativeMeetCallSession {
        let configuration = try #require(MeetCallConfiguration(
            apiKey: "synthetic-key", accountIndex: 0, referer: URL(string: "https://meet.google.com/call")!,
            userAgent: "Test", rtcClientID: "CAEQABgB", debugID: "synthetic-debug"
        ))
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "cookie-sentinel", domain: ".google.com", path: "/")
        ]))
        let client = MeetCallClient(
            transport: transport, credentials: SessionCredentials(cookies),
            configuration: configuration, sha1: { _ in "synthetic" }
        )
        let call = try await client.resolve(dmID: "synthetic-dm")
        return NativeMeetCallSession(
            client: client,
            call: call,
            media: media, staysWhenAlone: staysWhenAlone,
            validateAccount: validate,
            now: now
        )
    }

    static func responses(
        join: Bool = true, includeInvite: Bool = false, invalidMediaAnswer: Bool = false,
        ufrag: String = String(repeating: "U", count: 27) + "=", video: Bool = false
    ) -> [Result<HTTPResponse, any Error>] {
        var responses = [
            ok(
                string(1, "spaces/demo") + string(2, "abc-defg-hij")
                    + string(3, "https://meet.google.com/abc-defg-hij"),
                token: "10;resolved"
            ),
            ok(string(1, "mediasessions/native")
                + bytes(
                    2,
                    invalidMediaAnswer ? Data([0x08, 0x01]) : serverConfiguration(ufrag: ufrag, video: video)
                )),
            device(2, token: "20;registered")
        ]
        if join {
            responses.append(device(1, token: "30;joined"))
        }
        if includeInvite {
            responses.append(ok(string(1, "synthetic-invite")))
            responses.append(ok(Data(), token: "35;cancelled"))
        }
        responses.append(device(6, token: "40;left"))
        return responses
    }

    private static func serverConfiguration(ufrag: String, video: Bool) -> Data {
        let fingerprint = string(1, "sha-256") + string(2, digest)
        let dtls = bytes(1, fingerprint) + number(2, 2)
        let stun = string(3, ufrag) + string(4, String(repeating: "R", count: 27) + "=")
        let candidate = number(1, 1) + string(2, "127.0.0.1")
            + number(3, 3478) + number(4, 100) + number(5, 1)
        let codec = number(1, 111) + string(2, "opus")
            + number(3, 1) + number(4, 48000) + number(5, 2)
        let vp8 = number(1, 96) + string(2, "VP8") + number(3, 2) + number(4, 90000) + number(5, 1)
        let rtx = number(1, 97) + string(2, "rtx") + number(3, 2) + number(4, 90000) + number(5, 1)
            + bytes(6, string(1, "apt") + string(2, "96"))
        return bytes(1, dtls) + bytes(2, stun) + bytes(3, candidate) + bytes(4, codec)
            + (video ? bytes(4, vp8) + bytes(4, rtx) : Data())
    }

    private static func device(_ state: UInt64, token: String) -> Result<HTTPResponse, any Error> {
        ok(string(1, "spaces/demo/devices/one") + number(4, state), token: token)
    }

    static func ok(_ data: Data, token: String? = nil) -> Result<HTTPResponse, any Error> {
        .success(HTTPResponse(
            status: 200, headers: HTTPHeaders(token.map { [("x-goog-meeting-token", $0)] } ?? []),
            body: Data(data.base64EncodedString().utf8)
        ))
    }

    static func string(_ field: UInt64, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        unsigned(field << 3 | 2) + unsigned(UInt64(value.count)) + value
    }

    static func number(
        _ field: UInt64,
        _ value: UInt64
    ) -> Data {
        unsigned(field << 3) + unsigned(value)
    }

    private static func unsigned(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 128 {
            data.append(UInt8(value & 127) | 128); value >>= 7
        }
        data.append(UInt8(value))
        return data
    }
}
