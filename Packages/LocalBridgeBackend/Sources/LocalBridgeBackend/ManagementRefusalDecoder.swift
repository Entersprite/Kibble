import Foundation
import GChatBridgeCore

struct ManagementRefusalFields {
    let format: String
    let code: Int?
    let message: String?
    var wireShape: [String] = []
    var statusValues: [String: Int] = [:]
}

enum ManagementRefusalDecoder {
    static func decode(_ body: Data) -> ManagementRefusalFields {
        guard body.count <= 16384 else { return .init(format: "oversized", code: nil, message: nil) }
        if let json = try? JSONSerialization.jsonObject(with: body) {
            if let object = json as? [String: Any], let error = object["error"] as? [String: Any] {
                return .init(
                    format: "json",
                    code: error["code"] as? Int,
                    message: error["message"] as? String
                )
            }
            if let array = json as? [Any], array.count >= 2, let code = array[0] as? Int,
               let message = array[1] as? String {
                return .init(format: "pblite", code: code, message: message)
            }
            return .init(format: "json", code: nil, message: nil)
        }
        var shapes: [String] = []
        for candidate in APIResponseBody.candidates(body) {
            if let result = protobuf(
                candidate.bytes,
                encoding: candidate.encoding.rawValue,
                shapes: &shapes
            ) {
                return result
            }
        }
        let fallback = APIResponseBody.candidates(body).first
        let bytes = fallback?.bytes ?? body
        let printable = bytes.allSatisfy { (32 ... 126).contains($0) || [9, 10, 13].contains($0) }
        let text = String(decoding: bytes.prefix(2048), as: UTF8.self)
        guard !text.contains("<html"), !text.contains("<!DOCTYPE") else {
            return .init(format: "unrecognized", code: nil, message: nil, wireShape: shapes)
        }
        let words = text.unicodeScalars.map { scalar in
            scalar.value >= 32 && scalar.value <= 126 ? Character(scalar) : Character(" ")
        }
        return .init(
            format: printable ? "text" : "binary-text", code: nil, message: String(words), wireShape: shapes
        )
    }

    /// The reported native refusal carries numeric fields5/9 and a reason in10.
    /// Keep the numeric fields named by number until their semantics are established.
    private static func legacyFields(
        _ data: Data, encoding: String, shapes: [String]
    ) -> ManagementRefusalFields? {
        let fields = ProtoFieldScan.fields(in: data).fields
        guard fields.count == 3,
              fields.contains(where: { $0.number == 5 && $0.wireType == 0 && $0.byteCount <= 2 }),
              fields.contains(where: { $0.number == 9 && $0.wireType == 0 && $0.byteCount == 1 }),
              fields.contains(where: { $0.number == 10 && $0.wireType == 2 }),
              let first = ProtoFieldScan.varintValues(ofField: 5, in: data).first,
              let second = ProtoFieldScan.varintValues(ofField: 9, in: data).first,
              let bytes = ProtoFieldScan.payloads(ofField: 10, in: data).first else { return nil }
        // These are unclassified native values, not HTTP status codes. A binary
        // reason must not prevent the independent, width-bounded numbers surviving.
        let reason = String(data: bytes, encoding: .utf8)
        let detailShape = reason == nil ? ManagementBinaryDetailShape.describe(bytes) : []
        return .init(
            format: "protobuf-\(encoding)-5-9-10", code: nil, message: reason,
            wireShape: shapes + detailShape,
            statusValues: ["5": Int(first), "9": Int(second)]
        )
    }

    private static func protobuf(
        _ bytes: Data, encoding: String, shapes: inout [String]
    ) -> ManagementRefusalFields? {
        var pending = [(bytes, "root", 0)]
        var visited = 0
        while !pending.isEmpty, visited < 16 {
            let (node, path, depth) = pending.removeFirst()
            visited += 1
            let scan = ProtoFieldScan.fields(in: node)
            shapes += scan.fields.prefix(16).map {
                "\(encoding):\(path):\($0.number)/\($0.wireType)/\($0.byteCount)"
            }
            guard !scan.truncated else { continue }
            if let legacy = legacyFields(node, encoding: encoding, shapes: shapes) {
                return legacy
            }

            for (codeField, messageField) in [(1, 2), (2, 1), (3, 2)] {
                if let code = ProtoFieldScan.varintValues(ofField: codeField, in: node).first, code <= 599,
                   let payload = ProtoFieldScan.payloads(ofField: messageField, in: node).first,
                   let message = String(data: payload, encoding: .utf8), !message.isEmpty {
                    return .init(
                        format: "protobuf-\(encoding)-\(path)", code: Int(code), message: message,
                        wireShape: shapes
                    )
                }
            }
            guard depth < 3 else { continue }
            for number in Set(scan.fields.filter { $0.wireType == 2 }.map(\.number)).sorted().prefix(16) {
                let room = min(4, max(0, 64 - pending.count))
                pending += ProtoFieldScan.payloads(ofField: number, in: node).prefix(room).map {
                    ($0, "\(path).\(number)", depth + 1)
                }
            }
        }
        return nil
    }
}
