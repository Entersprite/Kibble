import Foundation

extension MeetAudioOffer {
    /// Fixed failure stages only. Never retain a server value or underlying
    /// parser error in a reportable error.
    public enum AnswerFailure: String, Error, Sendable {
        case configuration = "server configuration"
        case dtls = "DTLS fingerprint or role"
        case ice = "ICE credentials"
        case codecs = "audio codecs"
        case extensions = "RTP extensions"
        case candidates = "ICE candidates"
    }

    private struct AnswerTransport {
        let algorithm: String
        let digest: String
        let role: UInt64
        let ufrag: String
        let password: String

        var lines: [String] {
            [
                "a=ice-ufrag:\(ufrag)", "a=ice-pwd:\(password)", "a=fingerprint:\(algorithm) \(digest)",
                "a=setup:" + (role == 1 ? "active" : "passive")
            ]
        }
    }

    private struct NegotiatedCodec {
        let codec: Codec
        let formats: [String]
    }

    /// Rebuild the browser source's audio answer from server config. Preserve
    /// the offered MID and reject server codecs that weren't actually offered.
    public func answer(serverConfiguration data: Data) throws -> String {
        try Self.checked(.configuration) { try MeetProto.validate(data) }
        let transport = try Self.answerTransport(data)
        let accepted = try Self.checked(.codecs) {
            let codecs = try acceptedCodecs(data)
            guard !codecs.isEmpty else { throw AnswerFailure.codecs }
            return codecs
        }
        let extensions = try Self.checked(.extensions) { try acceptedExtensions(data) }
        let candidates = try Self.checked(.candidates) {
            let candidates = try serverCandidates(data)
            guard !candidates.isEmpty else { throw AnswerFailure.candidates }
            return candidates
        }
        var result = [
            "v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=-", "t=0 0",
            "a=group:BUNDLE " + [mid, dataMid].compactMap(\.self).joined(separator: " "),
            "a=ice-lite", "a=msid-semantic: WMS *",
            "m=audio 9 UDP/TLS/RTP/SAVPF " + accepted.map { String($0.codec.payload) }.joined(separator: " "),
            "c=IN IP4 0.0.0.0", "a=mid:\(mid)", "a=sendrecv", "a=rtcp-mux"
        ] + transport.lines
        for negotiated in accepted {
            let codec = negotiated.codec
            result.append("a=rtpmap:\(codec.payload) \(codec.name)/\(codec.rate)/\(codec.channels)")
            if !negotiated.formats.isEmpty {
                result.append("a=fmtp:\(codec.payload) " + negotiated.formats.joined(separator: ";"))
            }
        }
        // The server may offer more extensions than the native peer. Echo only
        // those in this peer's audio offer; unsupported ones stay unadvertised.
        result += extensions
        result += candidates
        result.append("a=end-of-candidates")
        if let dataMid {
            // EVg provides webrtc-datachannel/SCTP 5000 for the server
            // transport. Preserve the actual application's offered MID.
            result += [
                "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0",
                "a=mid:\(dataMid)", "a=sendrecv", "a=sctp-port:5000"
            ] + transport.lines
            result += candidates
            result.append("a=end-of-candidates")
        }
        return result.joined(separator: "\r\n") + "\r\n"
    }

    private static func checked<Output>(
        _ stage: AnswerFailure,
        _ body: () throws -> Output
    ) throws -> Output {
        do { return try body() } catch { throw stage }
    }

    private static func answerTransport(_ data: Data) throws -> AnswerTransport {
        let (algorithm, digest, role) = try checked(.dtls) {
            let dtls = try MeetProto.payload(1, data)
            let fingerprint = try MeetProto.payload(1, dtls)
            let algorithm = try MeetProto.text(1, fingerprint)
            let digest = try MeetProto.text(2, fingerprint)
            let role = try MeetProto.value(2, dtls)
            guard algorithm == "sha-256", validFingerprint(digest), role == 1 || role == 2 else {
                throw AnswerFailure.dtls
            }
            return (algorithm, digest, role)
        }
        let (ufrag, password) = try checked(.ice) {
            let stun = try MeetProto.payload(2, data)
            let ufrag = try MeetProto.text(3, stun)
            let password = try MeetProto.text(4, stun)
            guard validRemoteCredential(ufrag, minimum: 4),
                  validRemoteCredential(password, minimum: 22) else {
                throw AnswerFailure.ice
            }
            return (ufrag, password)
        }
        return AnswerTransport(
            algorithm: algorithm,
            digest: digest,
            role: role,
            ufrag: ufrag,
            password: password
        )
    }

    static func validRemoteCredential(_ value: String, minimum: Int) -> Bool {
        if validCredential(value, minimum: minimum) {
            return true
        }
        // The server converter preserves both opaque ICE strings. Its
        // accepted reference includes padding; apply the remote alphabet
        // consistently to fragments and passwords, retaining exact values.
        // Keep its exact opaque value; allow only terminal one/two '=' bytes,
        // bounded length and the already supported Base64 alphabet.
        let padding = value.utf8.reversed().prefix { $0 == 61 }.count
        return (minimum ... 256).contains(value.utf8.count) && value.utf8.count.isMultiple(of: 4)
            && (1 ... 2).contains(padding)
            && validCredential(String(value.dropLast(padding)), minimum: 1)
    }

    private func acceptedCodecs(_ data: Data) throws -> [NegotiatedCodec] {
        var accepted: [NegotiatedCodec] = []
        for bytes in ProtoFieldScan.payloads(ofField: 4, in: data) {
            try MeetProto.validate(bytes)
            guard try MeetProto.value(3, bytes) == 1 else { continue }
            let payload = try MeetProto.value(1, bytes)
            guard let local = codecs[payload],
                  try MeetProto.text(2, bytes).lowercased() == local.name.lowercased(),
                  try MeetProto.value(4, bytes) == local.rate,
                  try MeetProto.value(5, bytes) == local.channels else { continue }
            guard !accepted.contains(where: { $0.codec.payload == payload }) else {
                throw MeetCallWire.WireError.malformedResponse
            }
            let formats = try ProtoFieldScan.payloads(ofField: 6, in: bytes).map { entry in
                let keyData = try MeetProto.payload(1, entry)
                guard let key = String(data: keyData, encoding: .utf8), key.isEmpty || Self.atom(key) else {
                    throw MeetCallWire.WireError.malformedResponse
                }
                let value = try MeetProto.text(2, entry)
                guard Self.atom(value) else { throw MeetCallWire.WireError.malformedResponse }
                return key.isEmpty ? value : key + "=" + value
            }
            accepted.append(NegotiatedCodec(codec: local, formats: formats))
        }
        return accepted
    }

    private func acceptedExtensions(_ data: Data) throws -> [String] {
        var accepted: [String] = []
        for bytes in ProtoFieldScan.payloads(ofField: 5, in: data) {
            try MeetProto.validate(bytes)
            guard try MeetProto.value(3, bytes) == 1, try MeetProto.value(4, bytes) == 1 else { continue }
            let id = try MeetProto.value(1, bytes)
            let uri = try MeetProto.text(2, bytes)
            guard Self.atom(uri), (1 ... 255).contains(id) else { continue }
            let line = "a=extmap:\(id) \(uri)"
            if lines.contains(line) {
                accepted.append(line)
            }
        }
        return accepted
    }

    private func serverCandidates(_ data: Data) throws -> [String] {
        var candidates: [String] = []
        for (index, bytes) in ProtoFieldScan.payloads(ofField: 3, in: data).enumerated() {
            try MeetProto.validate(bytes)
            // Initial trial uses standard UDP ICE. TCP/SSLTCP fallback needs
            // native transport verification before it can be enabled.
            guard try MeetProto.value(1, bytes) == 1 else { continue }
            let address = try MeetProto.text(2, bytes)
            guard !address.isEmpty, address.utf8.allSatisfy({
                (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0)
                    || $0 == 46 || $0 == 58
            }) else { throw MeetCallWire.WireError.malformedResponse }
            let port = try MeetProto.value(3, bytes)
            let priority = try MeetProto.value(4, bytes)
            let type = try MeetProto.value(5, bytes)
            guard (1 ... 65535).contains(port), priority <= UInt32.max, (1 ... 4).contains(type) else {
                throw MeetCallWire.WireError.malformedResponse
            }
            let name = ["host", "prflx", "srflx", "relay"][Int(type - 1)]
            candidates.append("a=candidate:\(index + 1) 1 udp \(priority) \(address) \(port) typ \(name)")
        }
        return candidates
    }
}
