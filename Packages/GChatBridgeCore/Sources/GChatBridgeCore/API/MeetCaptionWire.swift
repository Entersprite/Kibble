import Foundation

/// Binary resource messages on the negotiated Meet captions channel.
public enum MeetCaptionWire {
    public enum Command: Sendable {
        case configure
        case subscribe

        var requestField: UInt64 {
            self == .configure ? 2 : 3
        }

        var responseField: Int {
            Int(requestField + 1)
        }
    }

    public enum CommandError: Error, Sendable { case rejected }

    public struct Resource: Sendable, Equatable {
        public let id: UInt64
        public let version: UInt64
    }

    public struct Languages: Sendable, Equatable {
        public let live: [String]
        public let translations: [String: [String]]

        public var isEmpty: Bool {
            live.isEmpty && translations.isEmpty
        }
    }

    public struct Settings: Sendable {
        public let version: UInt64
        public let languages: Languages
    }

    public struct Updates: Sendable {
        public let captions: [Change]
        public let settings: [Settings]
    }

    public struct Caption: Sendable, Equatable {
        public let resource: Resource
        public let text: String
        public let speaker: String
        public let displayLanguage: String?
        public let spokenLanguage: String?
        public let isFinal: Bool
    }

    public enum Change: Sendable, Equatable {
        case caption(Caption)
        case deletion(Resource)

        public var resource: Resource {
            switch self {
            case let .caption(caption): caption.resource
            case let .deletion(resource): resource
            }
        }
    }

    public static func subscribe(sequence: UInt64) throws -> Data {
        try request(.subscribe, payload: MeetProto.number(1, 1) + MeetProto.number(2, 1), sequence: sequence)
    }

    public static func configure(
        spokenLanguage: String, displayLanguage: String, automaticLanguage: Bool = false, sequence: UInt64
    ) throws -> Data {
        guard validLanguage(spokenLanguage), validLanguage(displayLanguage) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let config = MeetProto.string(2, displayLanguage) + MeetProto.string(3, spokenLanguage)
            + (automaticLanguage ? MeetProto.number(8, 1) : Data())
        return try request(.configure, payload: MeetProto.bytes(1, config), sequence: sequence)
    }

    public static func disable(sequence: UInt64) throws -> Data {
        try request(.configure, payload: MeetProto.bytes(1, Data()), sequence: sequence)
    }

    public static func matches(_ data: Data, command: Command, sequence: UInt64) -> Bool {
        (try? responseStatus(data, command: command, sequence: sequence)) != nil
    }

    public static func confirm(_ data: Data, command: Command, sequence: UInt64) throws {
        guard try responseStatus(data, command: command, sequence: sequence) == 0
        else { throw CommandError.rejected }
    }

    public static func updates(_ data: Data) throws -> Updates {
        try validateFrame(data)
        let updates = ProtoFieldScan.payloads(ofField: 1, in: data)
        let deletions = ProtoFieldScan.payloads(ofField: 4, in: data)
        guard updates.count + deletions.count <= 128 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return Updates(
            captions: updates.compactMap { try? caption(in: $0) }
                + deletions.compactMap { try? deletion(in: $0) },
            settings: updates.compactMap { try? settings(in: $0) }
        )
    }

    public static func acknowledge(_ resources: [Resource]) -> Data {
        resources.prefix(128).reduce(into: Data()) { result, resource in
            let acknowledgement = (resource.id == 0 ? Data() : MeetProto.number(1, resource.id))
                + (resource.version == 0 ? Data() : MeetProto.number(2, resource.version))
                + MeetProto.number(3, 1)
            result += MeetProto.bytes(1, acknowledgement)
        }
    }

    public static func acknowledgeSettings(_ versions: [UInt64]) -> Data {
        versions.prefix(128).reduce(into: Data()) { result, version in
            let revision = version == 0 ? Data() : MeetProto.number(2, version)
            result += MeetProto.bytes(1, revision + MeetProto.number(4, 1))
        }
    }

    static func languages(
        in data: Data, live: Int = 1, alternate: Int = 2, pairs: Int = 3
    ) throws -> Languages {
        try validateFrame(data)
        let speech = try languageTags(live, alternate, in: data)
        let rows = ProtoFieldScan.payloads(ofField: pairs, in: data)
        guard rows.count <= 256 else { throw MeetCallWire.WireError.malformedResponse }
        var targets: [String: [String]] = [:]
        for row in rows {
            let spoken = try MeetProto.text(1, row)
            guard validLanguage(spoken) else { throw MeetCallWire.WireError.malformedResponse }
            let displays = try languageTags(2, 3, in: row).filter { $0 != spoken }
            if !displays.isEmpty {
                targets[spoken] = try uniqueLanguages((targets[spoken] ?? []) + displays)
            }
        }
        return Languages(live: speech, translations: targets)
    }

    private static func languageTags(_ first: Int, _ second: Int, in data: Data) throws -> [String] {
        let values = ProtoFieldScan.payloads(ofField: first, in: data)
            + ProtoFieldScan.payloads(ofField: second, in: data)
        guard values.count <= 512 else { throw MeetCallWire.WireError.malformedResponse }
        let tags = values.compactMap { String(data: $0, encoding: .utf8) }.filter(validLanguage)
        return try uniqueLanguages(tags)
    }

    private static func uniqueLanguages(_ tags: [String]) throws -> [String] {
        var seen: Set<String> = []
        let unique = tags.filter { seen.insert($0).inserted }
        guard unique.count <= 256 else { throw MeetCallWire.WireError.malformedResponse }
        return unique
    }

    private static func settings(in update: Data) throws -> Settings {
        let body = try MeetProto.payload(4, update)
        guard !has(3, in: update), !has(6, in: update) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return try Settings(version: number(2, in: update), languages: languages(in: body))
    }

    private static func request(_ command: Command, payload: Data, sequence: UInt64) throws -> Data {
        guard sequence > 0 else { throw MeetCallWire.WireError.invalidIdentifier }
        // The first attempt uses protobuf's default retry ordinal zero.
        return MeetProto.bytes(
            2,
            MeetProto.number(1, sequence) + MeetProto.bytes(command.requestField, payload)
        )
    }

    private static func responseStatus(_ data: Data, command: Command, sequence: UInt64) throws -> UInt64 {
        try validateFrame(data)
        let reply = try MeetProto.payload(2, data)
        guard try MeetProto.value(1, reply) == sequence, try number(10001, in: reply) == 0
        else { throw MeetCallWire.WireError.malformedResponse }
        let status = try MeetProto.payload(2, reply)
        try MeetProto.validate(status)
        let code = try number(1, in: status)
        if code == 0 {
            let otherField = command == .configure ? 4 : 3
            guard !has(otherField, in: reply) else { throw MeetCallWire.WireError.malformedResponse }
            if has(command.responseField, in: reply) {
                try MeetProto.validate(MeetProto.payload(command.responseField, reply))
            }
        }
        return code
    }

    private static func caption(in update: Data) throws -> Change {
        let body = try MeetProto.payload(3, update)
        try MeetProto.validate(body)
        guard !has(4, in: update), !has(6, in: update) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let speaker = try string(6, in: body, limit: 512)
        let fallback = try Int32(truncatingIfNeeded: number(1, in: body))
        let isFinal = try number(10000, in: update)
        guard isFinal <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        return try .caption(Caption(
            resource: resource(in: update),
            text: string(3, in: body, limit: 16000) ?? "",
            speaker: speaker ?? String(fallback),
            displayLanguage: string(4, in: body, limit: 64),
            spokenLanguage: string(5, in: body, limit: 64),
            isFinal: isFinal == 1
        ))
    }

    private static func deletion(in update: Data) throws -> Change {
        guard try MeetProto.value(3, update) == 1 else { throw MeetCallWire.WireError.malformedResponse }
        return try .deletion(resource(in: update))
    }

    private static func resource(in data: Data) throws -> Resource {
        try Resource(id: number(1, in: data), version: number(2, in: data))
    }

    private static func number(_ field: Int, in data: Data) throws -> UInt64 {
        try has(field, in: data) ? MeetProto.value(field, data) : 0
    }

    private static func string(_ field: Int, in data: Data, limit: Int) throws -> String? {
        guard has(field, in: data) else { return nil }
        let bytes = try MeetProto.payload(field, data)
        guard bytes.count <= limit, let text = String(data: bytes, encoding: .utf8), !text.contains("\0")
        else { throw MeetCallWire.WireError.malformedResponse }
        return text.isEmpty ? nil : text
    }

    private static func has(_ field: Int, in data: Data) -> Bool {
        ProtoFieldScan.fields(in: data).fields.contains { $0.number == field }
    }

    private static func validateFrame(_ data: Data) throws {
        guard data.count <= 256_000 else { throw MeetCallWire.WireError.malformedResponse }
        try MeetProto.validate(data)
    }

    static func validLanguage(_ value: String) -> Bool {
        (2 ... 63).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45
        }
    }
}
