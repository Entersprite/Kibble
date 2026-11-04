import Foundation

public enum MeetActivityCollections {
    public struct Snapshot: Sendable {
        public var space: Data?
        public var messages: [Data]?
        public var polls: [Data]?
        public var questions: [Data]?
        public var breakout: Data?
        public var users: [Data]?
        public var pollSeries: [Data]?
        public var questionSeries: [Data]?
        public var versions: [Int: UInt64] = [:]
        public var unavailableFields: Set<Int> = []
    }

    public static func sync(space: String) -> Data {
        [2, 4, 5, 6, 7, 8, 9, 10]
            .reduce(MeetProto.string(1, space)) { $0 + MeetProto.bytes(UInt64($1), Data()) }
    }

    public static func decode(_ body: Data, space: String) throws -> Snapshot {
        try snapshot(body, space: space, isolatingFailures: false)
    }

    /// Optional activity failures must not discard the device/invitation state
    /// that drives ringing, peer joins, cleanup and termination.
    static func availableSnapshot(_ body: Data, space: String) throws -> Snapshot {
        try snapshot(body, space: space, isolatingFailures: true)
    }

    private static func snapshot(_ body: Data, space: String, isolatingFailures: Bool) throws -> Snapshot {
        let data = try MeetProto.decode(body)
        var result = Snapshot()
        for field in [1, 3, 4, 5, 6, 7, 8, 9] {
            do {
                guard let full = try full(field, data) else { continue }
                let version = try MeetCallCollectionsWire.version(full)
                try assign(field, full: full, space: space, result: &result)
                result.versions[field] = version
            } catch {
                guard isolatingFailures else { throw error }
                result.unavailableFields.insert(field)
            }
        }
        return result
    }

    private static func assign(_ field: Int, full: Data, space: String, result: inout Snapshot) throws {
        if [1, 8].contains(field) {
            try assignSingle(field, full: full, space: space, result: &result); return
        }
        let values = try collectionValues(full, field: field, space: space)
        switch field {
        case 3: result.messages = values
        case 4: result.polls = values
        case 5: result.pollSeries = values
        case 6: result.questions = values
        case 7: result.questionSeries = values
        case 9: result.users = values
        default: break
        }
    }

    private static func collectionValues(_ full: Data, field: Int, space: String) throws -> [Data] {
        let values = ProtoFieldScan.payloads(ofField: 2, in: full)
        guard values.count <= 256 else { throw MeetCallWire.WireError.malformedResponse }
        for value in values {
            try validateResource(value, field: field, space: space)
        }
        guard Set(values.compactMap { text(1, $0) }).count == values.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return values
    }

    private static func assignSingle(_ field: Int, full: Data, space: String, result: inout Snapshot) throws {
        // Native Meet explicitly accepts a breakout FULL with SyncMetadata only.
        // It is a known-empty collection, unlike absent/unmodified state.
        if field == 8, !has(2, full) {
            result.breakout = Data(); return
        }
        let payload = try MeetProto.payload(2, full)
        if field == 1 {
            guard try MeetProto.text(1, payload) == space
            else { throw MeetCallWire.WireError.malformedResponse }
            result.space = payload
        } else {
            let rooms = repeated(4, payload)
            guard rooms.count <= 100 else { throw MeetCallWire.WireError.malformedResponse }
            for room in rooms {
                try validateResource(room, field: 8, space: space)
            }
            guard Set(rooms.compactMap { text(1, $0) }).count == rooms.count else {
                throw MeetCallWire.WireError.malformedResponse
            }
            result.breakout = payload
        }
    }

    private static func validateResource(_ value: Data, field: Int, space: String) throws {
        try MeetProto.validate(value)
        let name = try MeetProto.text(1, value)
        guard !name.isEmpty, !name.contains("\0"),
              name.utf8.count <= 512 else { throw MeetCallWire.WireError.malformedResponse }
        if field != 3 {
            guard name.hasPrefix(space + "/"),
                  !name.contains("..") else { throw MeetCallWire.WireError.malformedResponse }
        }
    }

    static func full(_ field: Int, _ data: Data) throws -> Data? {
        guard has(field, data) else { return nil }
        let wrapper = try MeetProto.payload(field, data)
        let variants = ProtoFieldScan.fields(in: wrapper).fields.filter { [1, 2].contains($0.number) }
        guard variants.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        guard variants.first?.number == 2 else { return nil }
        return try MeetProto.payload(2, wrapper)
    }

    public static func has(_ field: Int, _ data: Data) -> Bool {
        ProtoFieldScan.fields(in: data).fields.contains { $0.number == field }
    }

    public static func bytes(_ field: Int, _ data: Data) throws -> Data {
        try MeetProto.payload(field, data)
    }

    public static func repeated(_ field: Int, _ data: Data) -> [Data] {
        ProtoFieldScan.payloads(
            ofField: field,
            in: data
        )
    }

    public static func text(_ field: Int, _ data: Data) -> String? {
        guard let value = try? MeetProto.payload(field, data), value.count <= 16000,
              let text = String(data: value, encoding: .utf8), !text.contains("\0") else { return nil }
        return text
    }

    public static func number(_ field: Int, _ data: Data) -> UInt64? {
        try? MeetProto.value(field, data)
    }
}
