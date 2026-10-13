import Foundation

/// Legacy audio-stream RPC carried by Meet's dcrpc data channel. Encoding a
/// packet does not open a channel, register a stream, or announce microphone state.
public enum MeetAudioStreamWire {
    /// Identity of this call's registered upstream audio stream. Never substitute
    /// a remote stream or reuse identifiers from another media session.
    public struct Stream: Sendable {
        private let sessionID: String
        private let conferenceID: String
        private let streamID: String

        public init(mediaSession: String, conferenceID: String, streamID: String) throws {
            guard MeetDeviceWire.validMediaSession(mediaSession),
                  MeetAudioStreamWire.validIdentifier(conferenceID),
                  MeetAudioStreamWire.validIdentifier(streamID) else {
                throw MeetCallWire.WireError.invalidIdentifier
            }
            sessionID = String(mediaSession.dropFirst("mediasessions/".count))
            self.conferenceID = conferenceID
            self.streamID = streamID
        }

        fileprivate var identity: Data {
            // Source Meet-14 i$g/I5g: direction UP=2, AUDIO=1; session3,
            // stream4, conference5. EVg removes the mediasessions/ prefix.
            MeetProto.number(1, 2) + MeetProto.number(2, 1)
                + MeetProto.string(3, sessionID) + MeetProto.string(4, streamID)
                + MeetProto.string(5, conferenceID)
        }

        fileprivate func matches(_ data: Data) throws -> Bool {
            try MeetProto.value(1, data) == 2 && MeetProto.value(2, data) == 1
                && (MeetAudioStreamWire.contextText(3, data) ?? sessionID) == sessionID
                && MeetProto.text(4, data) == streamID
                && (MeetAudioStreamWire.contextText(5, data) ?? conferenceID) == conferenceID
        }
    }

    /// Raw protobuf for an uncompressed channel. The request header must be
    /// supplied by the current call's adapter; no captured browser header is
    /// compiled in. Only a registered stream may be modified by the caller.
    public static func mute(
        stream: Stream, muted: Bool, requestID: UInt64, requestHeader: Data
    ) throws -> Data {
        guard validRequestID(requestID), !requestHeader.isEmpty, requestHeader.count <= 10000 else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        try MeetProto.validate(requestHeader)
        // N$g writes nI.10 -> Gyf.1, including explicit false on unmute.
        // z5g/Q7g carries streams4 and metadata3; V7g/X7g selects modify2.
        let value = stream.identity + MeetProto.bytes(10, MeetProto.number(1, muted ? 1 : 0))
        let modify = MeetProto.bytes(1, requestHeader) + MeetProto.bytes(3, Data())
            + MeetProto.bytes(4, value)
        return MeetProto.number(1, requestID) + MeetProto.bytes(2, modify)
    }

    /// Both success layers matter: google.rpc.Status code0 at outer4, and
    /// legacy response header status1 (not0) inside modify2/header1. Meet's
    /// client also accepts an empty stream list and inherits empty parent keys
    /// from the current collection. True means a scoped echo was validated;
    /// false means the request was acknowledged without an echo.
    @discardableResult
    public static func confirmMute(
        from data: Data, stream: Stream, muted: Bool, requestID: UInt64
    ) throws -> Bool {
        try confirm(from: data, stream: stream, muted: muted, requestID: requestID, variant: 2) != nil
    }

    /// Register the current sender before modifying it. i$g carries native
    /// SSRCs in stream8/SSRC1; U7g selects add4, with response variant5.
    public static func register(
        stream: Stream, ssrc: UInt32, muted: Bool, requestID: UInt64, requestHeader: Data
    ) throws -> Data {
        guard ssrc > 0 else { throw MeetCallWire.WireError.invalidIdentifier }
        _ = try mute(stream: stream, muted: muted, requestID: requestID, requestHeader: requestHeader)
        let source = MeetProto.bytes(1, MeetProto.unsigned(UInt64(ssrc)))
        let value = stream.identity + MeetProto.bytes(8, source)
            + MeetProto.bytes(10, MeetProto.number(1, muted ? 1 : 0))
        let add = MeetProto.bytes(1, requestHeader) + MeetProto.bytes(3, Data()) + MeetProto.bytes(4, value)
        return MeetProto.number(1, requestID) + MeetProto.bytes(4, add)
    }

    @discardableResult
    public static func confirmRegistration(
        from data: Data, stream: Stream, ssrc: UInt32, muted: Bool, requestID: UInt64
    ) throws -> Bool {
        guard ssrc > 0 else { throw MeetCallWire.WireError.malformedResponse }
        guard let echoed = try confirm(
            from: data, stream: stream, muted: muted, requestID: requestID, variant: 5
        ) else { return false }
        let source = try MeetProto.payload(8, echoed)
        var values = ProtoFieldScan.varintValues(ofField: 1, in: source)
        for packed in ProtoFieldScan.payloads(ofField: 1, in: source) {
            values += try packedSSRCs(packed)
        }
        guard values == [UInt64(ssrc)], ssrc > 0 else { throw MeetCallWire.WireError.malformedResponse }
        return true
    }

    private static func packedSSRCs(_ data: Data) throws -> [UInt64] {
        var result: [UInt64] = []
        var value: UInt64 = 0
        var shift = 0
        for byte in data {
            guard shift < 35, result.count < 8 else { throw MeetCallWire.WireError.malformedResponse }
            value |= UInt64(byte & 127) << shift
            if byte < 128 {
                guard value <= UInt32.max else { throw MeetCallWire.WireError.malformedResponse }
                result.append(value)
                value = 0; shift = 0
            } else {
                shift += 7
            }
        }
        guard shift == 0 else { throw MeetCallWire.WireError.malformedResponse }
        return result
    }

    public static func matchesRequest(_ data: Data, requestID: UInt64) -> Bool {
        data.count <= 1_000_000 && (try? MeetProto.value(1, data)) == requestID
    }

    /// Fixed enum diagnostics only: never server descriptions or identifiers.
    public static func replyDiagnostic(_ data: Data) -> String {
        guard data.count <= 1_000_000, let status = try? MeetProto.payload(4, data) else {
            return "outer status absent or invalid"
        }
        let code = (try? MeetProto.value(1, status)) ?? (status.isEmpty ? 0 : nil)
        let outer = code.flatMap { $0 <= 16 ? String($0) : nil } ?? "unrecognized"
        let variants = [2, 5].filter { !ProtoFieldScan.payloads(ofField: $0, in: data).isEmpty }
        guard variants.count == 1, let operation = try? MeetProto.payload(variants[0], data),
              let header = try? MeetProto.payload(1, operation), let legacy = try? MeetProto.value(1, header),
              legacy <= 16 else { return "outer code " + outer + "; legacy status absent or invalid" }
        let echoes = ProtoFieldScan.fields(in: operation).fields.filter { $0.number == 4 }.count
        return "outer code " + outer + "; legacy status " + String(legacy)
            + "; stream echoes " + String(echoes)
    }

    private static func confirm(
        from data: Data, stream: Stream, muted: Bool, requestID: UInt64, variant: Int
    ) throws -> Data? {
        guard validRequestID(requestID), data.count <= 1_000_000 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        try MeetProto.validate(data)
        guard try MeetProto.value(1, data) == requestID else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let status = try MeetProto.payload(4, data)
        try MeetProto.validate(status)
        let code = try ProtoFieldScan.fields(in: status).fields.contains { $0.number == 1 }
            ? MeetProto.value(1, status) : 0
        guard code == 0 else { throw MeetCallWire.WireError.malformedResponse }
        let variants = ProtoFieldScan.fields(in: data).fields.filter { [2, 3, 5].contains($0.number) }
        guard variants.count == 1, variants[0].number == variant else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let modify = try MeetProto.payload(variant, data)
        let header = try MeetProto.payload(1, modify)
        guard try MeetProto.value(1, header) == 1 else { throw MeetCallWire.WireError.malformedResponse }
        // Bah/vWg validate status; x5g/z5g return a repeated list and C5g
        // explicitly resolves an empty list. Do not invent an echoed state.
        guard ProtoFieldScan.fields(in: modify).fields.contains(where: { $0.number == 4 }) else {
            return nil
        }
        let echoed = try MeetProto.payload(4, modify)
        guard try stream.matches(echoed) else { throw MeetCallWire.WireError.malformedResponse }
        let flag = try muteFlag(echoed)
        guard flag == (muted ? 1 : 0) else { throw MeetCallWire.WireError.malformedResponse }
        return echoed
    }

    private static func muteFlag(_ data: Data) throws -> UInt64 {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == 10 }) else { return 0 }
        let state = try MeetProto.payload(10, data)
        try MeetProto.validate(state)
        guard ProtoFieldScan.fields(in: state).fields.contains(where: { $0.number == 1 }) else { return 0 }
        return try MeetProto.value(1, state)
    }

    private static func validRequestID(_ value: UInt64) -> Bool {
        (1 ... UInt64(UInt32.max)).contains(value)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (33 ... 126).contains($0) }
    }

    private static func contextText(_ field: Int, _ data: Data) throws -> String? {
        try MeetProto.validate(data)
        // Meet-14 m5g/n5g: falsey parent getters inherit the current collection's
        // keys. Only absent or a single empty string may inherit native scope;
        // duplicate, mistyped, malformed or foreign supplied values must reject.
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field }) else {
            return nil
        }
        let bytes = try MeetProto.payload(field, data)
        guard !bytes.isEmpty else { return nil }
        return try MeetProto.text(field, data)
    }
}

public extension MeetAudioStreamWire {
    /// Compare only with this call's expected values. Never render a returned
    /// identifier, SSRC, message or unknown numeric value.
    static func registrationDiagnostic(
        from data: Data, stream: Stream, ssrc: UInt32, muted: Bool, requestID: UInt64
    ) -> String {
        guard data.count <= 1_000_000, (try? MeetProto.validate(data)) != nil else {
            return "reply structure invalid"
        }
        var checks = ["request " + diagnosticValue(try? MeetProto.value(1, data), expected: requestID)]
        guard let operation = try? MeetProto.payload(5, data) else {
            return (checks + ["add response missing or invalid"]).joined(separator: "; ")
        }
        guard let echo = try? MeetProto.payload(4, operation) else {
            return (checks + ["stream echo missing or invalid"]).joined(separator: "; ")
        }
        let own = stream.identity
        for (field, label) in [(1, "direction"), (2, "media kind")] {
            checks.append(label + " " + diagnosticValue(
                try? MeetProto.value(field, echo), expected: try? MeetProto.value(field, own)
            ))
        }
        for (field, label) in [(3, "session"), (4, "stream"), (5, "conference")] {
            if field != 4, let inherited = try? contextIsInherited(field, echo), inherited {
                checks.append(label + " inherited from current call")
                continue
            }
            checks.append(label + " " + diagnosticValue(
                try? MeetProto.text(field, echo), expected: try? MeetProto.text(field, own)
            ))
        }
        checks.append("mute " + diagnosticValue(try? muteFlag(echo), expected: muted ? 1 : 0))
        if let source = try? MeetProto.payload(8, echo), (try? MeetProto.validate(source)) != nil {
            var values = ProtoFieldScan.varintValues(ofField: 1, in: source)
            for packed in ProtoFieldScan.payloads(ofField: 1, in: source) {
                guard let decoded = try? packedSSRCs(packed) else {
                    return (checks + ["SSRC invalid"]).joined(separator: "; ")
                }
                values += decoded
            }
            checks.append("SSRC " + (values == [UInt64(ssrc)] ? "matches" : "differs"))
        } else {
            checks.append("SSRC missing or invalid")
        }
        return checks.joined(separator: "; ")
    }

    private static func diagnosticValue<T: Equatable>(_ value: T?, expected: T?) -> String {
        guard let value, let expected else { return "missing or invalid" }
        return value == expected ? "matches" : "differs"
    }

    private static func contextIsInherited(_ field: Int, _ data: Data) throws -> Bool {
        try contextText(field, data) == nil
    }
}
