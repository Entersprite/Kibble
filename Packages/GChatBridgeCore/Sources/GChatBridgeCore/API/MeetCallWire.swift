import Foundation

/// The small part of Meet's private call protocol observed in a Chat DM call.
/// This is wire handling only: building either request does not send it, and
/// `CreateMeetingInvite` must never be sent as a background side effect.
public enum MeetCallWire {
    public struct Space: Sendable, Equatable {
        public let name: String
        public let code: String
        public let url: URL

        public init(name: String, code: String, url: URL) {
            self.name = name
            self.code = code
            self.url = url
        }
    }

    public enum WireError: Error, Sendable, Equatable {
        case invalidIdentifier
        case malformedResponse
    }

    /// `MeetingSpaceService/ResolveForHangoutsChat`, as measured in §66.3.
    /// The bare Chat DM id is field 7; the `dm:` domain prefix is not sent.
    public static func resolve(dmID: String) throws -> Data {
        guard validIdentifier(dmID) else { throw WireError.invalidIdentifier }
        var body = Data()
        appendVarint(2, field: 1, to: &body)
        appendVarint(1, field: 2, to: &body)
        appendString(dmID, field: 7, to: &body)
        return body
    }

    /// Meet's receiver hih/Xnf flow resolves the offered meeting code at
    /// field 1. It does not resolve/create the Chat DM's outgoing call space.
    public static func resolveOffered(code: String) throws -> Data {
        guard validIdentifier(code) else { throw WireError.invalidIdentifier }
        return MeetProto.string(1, code)
    }

    /// hih/gih also sends MeetingIdentifier(type=2, value=offered code).
    public static func offeredIdentifier(code: String) throws -> String {
        _ = try resolveOffered(code: code)
        return (MeetProto.number(1, 2) + MeetProto.string(2, code)).base64EncodedString()
    }

    /// The response body is base64 binary protobuf when the request asks for
    /// `x-goog-encode-response-if-executable: base64`.
    public static func resolvedSpace(from body: Data) throws -> Space {
        let protobuf = try decodedResponse(body)
        let scan = ProtoFieldScan.fields(in: protobuf)
        guard !scan.truncated,
              let name = singleString(1, in: protobuf), name.hasPrefix("spaces/"),
              let code = singleString(2, in: protobuf), !code.isEmpty,
              let address = singleString(3, in: protobuf),
              let url = URL(string: address),
              url.scheme == "https", url.host == "meet.google.com",
              url.path == "/\(code)", url.query == nil, url.fragment == nil
        else { throw WireError.malformedResponse }
        return Space(name: name, code: code, url: url)
    }

    /// `MeetingInviteService/CreateMeetingInvite`. Sending this is the action
    /// that rings the person. `requestID` is fresh per attempt, not a retry key
    /// to share between unrelated calls. The captured UUID is uppercase.
    public static func invite(spaceName: String, calleeID: String, requestID: UUID) throws -> Data {
        guard spaceName.hasPrefix("spaces/"), spaceName.count > "spaces/".count,
              validIdentifier(calleeID)
        else { throw WireError.invalidIdentifier }
        var callee = Data()
        appendString(calleeID, field: 2, to: &callee)
        var body = Data()
        appendString(spaceName, field: 1, to: &body)
        appendBytes(callee, field: 2, to: &body)
        appendVarint(2, field: 3, to: &body)
        appendVarint(1, field: 4, to: &body)
        appendString(requestID.uuidString, field: 12, to: &body)
        return body
    }

    /// The captured successful invite carried an opaque identifier in field 1.
    /// This checks presence only; the meaning of its other fields is unverified.
    public static func acceptedInvite(from body: Data) throws -> Bool {
        let protobuf = try decodedResponse(body)
        let scan = ProtoFieldScan.fields(in: protobuf)
        guard !scan.truncated else { throw WireError.malformedResponse }
        return singleString(1, in: protobuf) != nil
    }

    private static func decodedResponse(_ body: Data) throws -> Data {
        guard let text = String(data: body, encoding: .utf8),
              let protobuf = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw WireError.malformedResponse }
        return protobuf
    }

    private static func singleString(_ field: Int, in data: Data) -> String? {
        let payloads = ProtoFieldScan.payloads(ofField: field, in: data)
        guard payloads.count == 1, let value = String(data: payloads[0], encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0)
                || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_")
        }
    }

    private static func appendVarint(_ value: UInt64, field: UInt64, to data: inout Data) {
        appendUnsigned(field << 3, to: &data)
        appendUnsigned(value, to: &data)
    }

    private static func appendString(_ value: String, field: UInt64, to data: inout Data) {
        appendBytes(Data(value.utf8), field: field, to: &data)
    }

    private static func appendBytes(_ value: Data, field: UInt64, to data: inout Data) {
        appendUnsigned(field << 3 | 2, to: &data)
        appendUnsigned(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendUnsigned(_ value: UInt64, to data: inout Data) {
        var remainder = value
        while remainder >= 0x80 {
            data.append(UInt8(remainder & 0x7F) | 0x80)
            remainder >>= 7
        }
        data.append(UInt8(remainder))
    }
}
