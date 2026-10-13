import Foundation

/// Private provider notifications. Resource IDs and notification context stay
/// in the provider; callers must never print these values in diagnostics.
public enum MeetPushWire {
    public struct Ring: Sendable {
        public let id: String
        public let callIdentifier: String
        public let dmID: String
        public let notificationContext: String?
        public let receiverClientID: String?
        public let kind: UInt64
    }

    public enum Event: Sendable {
        case started
        case ring(Ring)
        case ended(id: String, reason: UInt64?)
        case stopped(code: Int?)
    }

    /// IQh unwraps the single CQh in WebChannel data before rRh reads its
    /// repeated field-1 watch responses. Watch field 2 -> event field 2 ->
    /// changes; change field 2 carries binary MeetPayload.
    public static func events(in value: PBLiteValue) throws -> [Event] {
        guard let outer = value.arrayValue, outer.count == 1,
              let response = outer[0].arrayValue,
              let watches = response.first?.arrayValue else { return [] }
        var result: [Event] = []
        guard watches.count <= 256 else { throw MeetCallWire.WireError.malformedResponse }
        for watch in watches {
            guard let fields = watch.arrayValue, fields.count >= 2,
                  fields[0].stringValue == "1" || fields[0].intValue == 1 else { continue }
            if fields.count > 2, let status = fields[2].arrayValue {
                result.append(.stopped(code: status.first?.arrayValue?.first?.intValue))
                continue
            }
            try result.append(contentsOf: watchEvents(fields[1]))
        }
        return result
    }

    /// Structural counts only. Never include raw strings, numbers from IDs,
    /// subscription versions, status messages or channel credentials.
    public static func envelopeSummary(_ value: PBLiteValue) -> String {
        guard let outer = value.arrayValue, outer.count == 1,
              let response = outer[0].arrayValue else { return "control or unrecognized envelope" }
        guard let watches = response.first?.arrayValue else { return "response without watch list" }
        let matching = watches.filter {
            guard let fields = $0.arrayValue, !fields.isEmpty else { return false }
            return fields[0].stringValue == "1" || fields[0].intValue == 1
        }
        return "watch responses \(watches.count); matching sequence \(matching.count)"
    }

    private static func watchEvents(_ value: PBLiteValue) throws -> [Event] {
        guard let event = value.arrayValue else { return [] }
        var result: [Event] = []
        if event.first?.arrayValue != nil {
            result.append(.started)
        }
        guard event.count > 1, let changes = event[1].arrayValue?.first?.arrayValue else { return result }
        guard changes.count <= 256 else { throw MeetCallWire.WireError.malformedResponse }
        for change in changes {
            guard let fields = change.arrayValue, fields.count >= 6,
                  fields[5].arrayValue != nil, fields[2].stringValue != nil || fields[2].intValue != nil,
                  let encoded = fields[1].stringValue else { continue }
            if let event = try payload(notificationBytes(encoded)) {
                result.append(event)
            }
        }
        return result
    }

    public static func payload(_ data: Data) throws -> Event? {
        guard !data.isEmpty, data.count <= 64000 else { throw MeetCallWire.WireError.malformedResponse }
        try MeetProto.validate(data)
        let variants = ProtoFieldScan.fields(in: data).fields.filter { [1, 2, 4, 5, 6].contains($0.number) }
        guard variants.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        guard let variant = variants.first else { return nil }
        switch variant.number {
        case 1: return try incoming(MeetProto.payload(1, data))
        case 2:
            let ended = try MeetProto.payload(2, data)
            let id = try identifier(1, ended, maximum: 4096)
            let reason = try optionalNumber(2, ended)
            return .ended(id: id, reason: reason)
        default: return nil
        }
    }

    private static func incoming(_ data: Data) throws -> Event? {
        let type = try MeetProto.value(4, data)
        let kind = try MeetProto.value(12, data)
        guard type == 1, kind != 0 else { return nil }
        return try .ring(Ring(
            id: identifier(1, data, maximum: 4096),
            callIdentifier: identifier(2, data, maximum: 4096),
            dmID: identifier(11, data, maximum: 256),
            notificationContext: optionalIdentifier(7, data, maximum: 4096),
            receiverClientID: optionalIdentifier(8, data, maximum: 4096),
            kind: kind
        ))
    }

    private static func identifier(_ field: Int, _ data: Data, maximum: Int) throws -> String {
        let value = try MeetProto.text(field, data)
        guard value.utf8.count <= maximum, value.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return value
    }

    private static func optionalIdentifier(_ field: Int, _ data: Data, maximum: Int) throws -> String? {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return nil }
        return try identifier(field, data, maximum: maximum)
    }

    private static func optionalNumber(_ field: Int, _ data: Data) throws -> UInt64? {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return nil }
        return try MeetProto.value(field, data)
    }

    private static func notificationBytes(_ value: String) throws -> Data {
        guard value.utf8.count <= 90000 else { throw MeetCallWire.WireError.malformedResponse }
        let normal = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normal + String(repeating: "=", count: (4 - normal.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded) else { throw MeetCallWire.WireError.malformedResponse }
        return bytes
    }
}
