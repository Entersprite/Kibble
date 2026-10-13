import Foundation

/// Initial native audio negotiation with an optional bundled SCTP transport
/// for server-created collections pushes. Video remains unsupported.
public struct MeetAudioOffer: Sendable {
    public enum SRTPSuite: UInt64, Sendable {
        case aes128SHA180 = 1
        case aeadAES128GCM = 2
        case aeadAES256GCM = 3
    }

    let lines: [String]
    let mid: String
    let dataMid: String?
    let codecs: [UInt64: Codec]
    public let clientConfiguration: Data

    struct Codec: Sendable, Equatable {
        let payload: UInt64
        let name: String
        let rate: UInt64
        let channels: UInt64

        var protobuf: Data {
            MeetProto.number(1, payload) + MeetProto.string(2, name)
                + MeetProto.number(3, 1) + MeetProto.number(4, rate) + MeetProto.number(5, channels)
        }
    }

    public init(sdp: String, srtpSuite: SRTPSuite = .aes128SHA180, collections: Bool = false) throws {
        guard sdp.utf8.count < 100_000, !sdp.contains("\0") else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let sections = try Self.mediaSections(sdp, collections: collections)
        lines = sections.audio
        let media = lines.filter { $0.hasPrefix("m=") }
        mid = try Self.single("a=mid:", lines)
        dataMid = try Self.bundledDataMid(sections, audioMid: mid)
        let fingerprint = try Self.single("a=fingerprint:", lines).components(separatedBy: " ")
        guard fingerprint.count == 2, fingerprint[0] == "sha-256",
              Self.validFingerprint(fingerprint[1]),
              try Self.single("a=setup:", lines) == "actpass" else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let ufrag = try Self.single("a=ice-ufrag:", lines)
        let password = try Self.single("a=ice-pwd:", lines)
        guard Self.validCredential(ufrag, minimum: 4), Self.validCredential(password, minimum: 22),
              Self.atom(mid) else { throw MeetCallWire.WireError.malformedResponse }
        var mapped: [UInt64: Codec] = [:]
        var configuration = Data()
        let digest = MeetProto.string(1, fingerprint[0]) + MeetProto.string(2, fingerprint[1])
        // DTLS role ACTPASS=3. The injected engine supplies its SRTP
        // preference separately because standard SDP does not convey it.
        // Meet's converter always supplies DTLS field 5: 1 for its default
        // path, 2 only for an enabled experimental flag. This selector is
        // separate from the DTLS role and SRTP cipher above.
        let dtls = MeetProto.bytes(1, digest) + MeetProto.number(2, 3)
            + MeetProto.number(3, srtpSuite.rawValue) + MeetProto.number(5, 1)
        configuration += MeetProto.bytes(1, dtls)
        configuration += MeetProto.bytes(2, MeetProto.string(3, ufrag) + MeetProto.string(4, password))
        let encoded = try Self.encodeCodecs(lines)
        let payloads = Set(media[0].split(separator: " ").dropFirst(3).compactMap { UInt64($0) })
        guard encoded.codecs.keys.allSatisfy(payloads.contains) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        configuration += encoded.data
        mapped = encoded.codecs
        configuration += Self.encodeExtensions(lines)
        if collections {
            // Source q4g/s4g: PROTOBUF=1, COMPRESSION_NONE=1. This is the
            // server-created push channel; no unsupported local channels.
            configuration += MeetProto.bytes(8, MeetProto.number(1, 1) + MeetProto.number(2, 1))
        }
        // pVg always writes selector 36=2. Field 44 is the inverse of
        // audio output enabled (T6c.1 -> H9c.5). Leave that disable flag
        // absent/false for this bidirectional audio peer.
        configuration += MeetProto.number(36, 2)
        codecs = mapped
        clientConfiguration = configuration
    }

    private static func encodeCodecs(_ lines: [String]) throws -> (data: Data, codecs: [UInt64: Codec]) {
        var mapped: [UInt64: Codec] = [:]
        var configuration = Data()
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let codec = try Self.codec(String(line.dropFirst("a=rtpmap:".count)))
            guard mapped.updateValue(codec, forKey: codec.payload) == nil else {
                throw MeetCallWire.WireError.malformedResponse
            }
            var bytes = codec.protobuf
            for format in lines where format.hasPrefix("a=fmtp:\(codec.payload) ") {
                let parameters = format.dropFirst("a=fmtp:\(codec.payload) ".count).split(separator: ";")
                for parameter in parameters {
                    let pair = parameter.trimmingCharacters(in: .whitespaces).split(
                        separator: "=", maxSplits: 1, omittingEmptySubsequences: false
                    )
                    let key = pair.count == 2 ? String(pair[0]) : ""
                    let value = String(pair[pair.count - 1])
                    let entry = MeetProto.string(1, key) + MeetProto.string(2, value)
                    bytes += MeetProto.bytes(6, entry)
                }
            }
            configuration += MeetProto.bytes(3, bytes)
        }
        guard mapped.values.contains(where: { $0.name.lowercased() == "opus" && $0.rate == 48000 }) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return (configuration, mapped)
    }

    private static func encodeExtensions(_ lines: [String]) -> Data {
        var configuration = Data()
        for line in lines where line.hasPrefix("a=extmap:") {
            let parts = line.dropFirst("a=extmap:".count).split(separator: " ")
            guard parts.count == 2, let id = UInt64(parts[0]), (1 ... 255).contains(id),
                  Self.atom(String(parts[1])) else { continue }
            let value = MeetProto.number(1, id) + MeetProto.string(2, String(parts[1]))
                + MeetProto.number(3, 1) + MeetProto.number(4, 1)
            configuration += MeetProto.bytes(4, value)
        }
        return configuration
    }

    static func single(_ prefix: String, _ lines: [String]) throws -> String {
        let values = lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard values.count == 1, !values[0].isEmpty else { throw MeetCallWire.WireError.malformedResponse }
        return values[0]
    }

    static func atom(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy { (33 ... 126).contains($0) }
    }

    static func validCredential(_ value: String, minimum: Int) -> Bool {
        (minimum ... 256).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 43 || $0 == 47
        }
    }

    static func validFingerprint(_ value: String) -> Bool {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 32 && octets.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }

    private static func codec(_ value: String) throws -> Codec {
        let parts = value.split(separator: " ")
        guard parts.count == 2, let payload = UInt64(parts[0]), payload <= 127 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let encoding = parts[1].split(separator: "/")
        guard (2 ... 3).contains(encoding.count), let rate = UInt64(encoding[1]), rate > 0,
              atom(String(encoding[0])) else { throw MeetCallWire.WireError.malformedResponse }
        let channels = encoding.count == 3 ? UInt64(encoding[2]) : 1
        guard let channels,
              ["opus", "red"].contains(encoding[0].lowercased()), rate == 48000,
              channels == 2 else { throw MeetCallWire.WireError.malformedResponse }
        return Codec(payload: payload, name: String(encoding[0]), rate: rate, channels: channels)
    }
}
