import Foundation

/// `X-Goog-Meeting-RtcClient` is base64 of the client descriptor protobuf,
/// not a random client identifier. Meet's shell supplies `JyGAEc`; its web
/// client removes the four-character tag, parses the positional JSON and
/// serializes the seven enum fields. Missing configuration takes the
/// desktop web default from `JNc(0)`. Malformed configuration stops the call.
enum MeetCallRTCClient {
    static func extract(from html: Data) -> String? {
        guard let text = String(data: html, encoding: .utf8),
              let fields = WizGlobalData.fields(in: text) else { return nil }
        guard let configured = fields["JyGAEc"] else { return encode([1, 0, 1]) }
        guard let tagged = configured as? String, tagged.utf8.count <= 512, tagged.count >= 4,
              let value = try? PBLiteValue(json: Data(("[" + tagged.dropFirst(4)).utf8)),
              let values = value.arrayValue, (3 ... 7).contains(values.count),
              values.prefix(3).allSatisfy({ $0.intValue != nil })
        else { return nil }
        var descriptor: [UInt32?] = []
        for value in values {
            if value.isNull {
                descriptor.append(nil)
            } else {
                guard case let .number(number) = value, let integer: UInt32 = number.exactInteger(),
                      integer <= UInt32(Int32.max)
                else { return nil }
                descriptor.append(integer)
            }
        }
        return encode(descriptor)
    }

    static func isValid(_ header: String) -> Bool {
        guard header.utf8.count <= 128, let bytes = Data(base64Encoded: header) else { return false }
        let scan = ProtoFieldScan.fields(in: bytes)
        let numbers = scan.fields.map(\.number)
        return !scan.truncated && Set(numbers).count == numbers.count
            && [1, 2, 3].allSatisfy(numbers.contains)
            && scan.fields.allSatisfy { field in
                (1 ... 7).contains(field.number) && field.wireType == 0
                    && ProtoFieldScan.varintValues(ofField: field.number, in: bytes)
                    .allSatisfy { $0 <= UInt64(Int32.max) }
            }
    }

    private static func encode(_ fields: [UInt32?]) -> String {
        var bytes = Data()
        for (index, value) in fields.enumerated() {
            guard let value else { continue }
            append(UInt64(index + 1) << 3, to: &bytes)
            append(UInt64(value), to: &bytes)
        }
        return bytes.base64EncodedString()
    }

    private static func append(_ value: UInt64, to bytes: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }
}
