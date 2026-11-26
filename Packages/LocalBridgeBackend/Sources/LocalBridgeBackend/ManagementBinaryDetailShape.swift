import Foundation
import GChatBridgeCore

/// Error structure and the known application-error code; no strings, raw bytes or headers.
enum ManagementBinaryDetailShape {
    static func describe(_ data: Data) -> [String] {
        var pending = [(data, "detail10", 0)]
        var result: [String] = []
        var visited = 0
        while !pending.isEmpty, visited < 16, result.count < 64 {
            let (node, path, depth) = pending.removeFirst()
            visited += 1
            if let items = messageSet(node) {
                for (type, payload) in items {
                    // MessageSet type IDs are public schema extension numbers.
                    result.append("\(path):messageSet:\(type)")
                    // DynamiteError (dfe.der.de): its field1 is an application
                    // error number, not an account/resource identifier.
                    if path == "detail10", type == 156_118_257,
                       let code = ProtoFieldScan.varintValues(ofField: 1, in: payload).first,
                       code <= Int32.max {
                        result.append("\(path):applicationCode=\(code)")
                    }
                    if depth < 3, pending.count < 64 {
                        pending.append((payload, "\(path).extension\(type)", depth + 1))
                    }
                }
                continue
            }
            let scan = ProtoFieldScan.fields(in: node)
            for field in scan.fields.prefix(16) {
                var shape = "\(path):\(field.number)/\(field.wireType)/\(field.byteCount)"
                if field.wireType == 0,
                   let value = ProtoFieldScan.varintValues(ofField: field.number, in: node).first,
                   value <= 16 {
                    shape += "=\(value)"
                }
                result.append(shape)
            }
            guard !scan.truncated, depth < 3 else { continue }
            for number in Set(scan.fields.filter { $0.wireType == 2 }.map(\.number)).sorted().prefix(16) {
                let room = min(4, max(0, 64 - pending.count))
                pending += ProtoFieldScan.payloads(ofField: number, in: node).prefix(room).map {
                    ($0, "\(path).\(number)", depth + 1)
                }
            }
        }
        return Array(result.prefix(64))
    }

    /// Standard MessageSet: group1 { uint32 type_id2; bytes message3; }.
    /// Ordinary field scanning intentionally refuses groups; do not relax that scanner.
    private static func messageSet(_ data: Data) -> [(UInt32, Data)]? {
        let bytes = Array(data)
        var offset = 0
        var result: [(UInt32, Data)] = []
        while offset < bytes.count, result.count < 16 {
            guard read(bytes, at: &offset) == 11 else { return nil }
            var type: UInt32?
            var payload: Data?
            for _ in 0 ..< 2 {
                switch read(bytes, at: &offset) {
                case 16 where type == nil:
                    type = read(bytes, at: &offset)
                case 26 where payload == nil:
                    guard let size = read(bytes, at: &offset), Int(size) <= bytes.count - offset
                    else { return nil }
                    payload = Data(bytes[offset ..< offset + Int(size)])
                    offset += Int(size)
                default: return nil
                }
            }
            guard let type, type > 0, type < 1 << 29, let payload,
                  read(bytes, at: &offset) == 12 else { return nil }
            result.append((type, payload))
        }
        return offset == bytes.count && !result.isEmpty ? result : nil
    }

    private static func read(_ bytes: [UInt8], at offset: inout Int) -> UInt32? {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            guard shift < 28 || byte < 16 else { return nil }
            value |= UInt32(byte & 127) << shift
            if byte & 128 == 0 {
                return value
            }
        }
        return nil
    }
}
