import Foundation

/// Read-only call participants, using the web client's group reference and
/// explicit participant fetch option. Neither building nor sending this rings.
public enum CallDiscoveryRequests {
    public static let rpc = "v54cwf"

    public struct Participants: Sendable, Equatable {
        public let memberIDs: [String]
        public let anonymousNames: [String?]
        public let totalCount: Int
    }

    public enum Failure: Error { case invalidGroup, malformedParticipants }

    public static func participants(in group: GroupId) throws -> BatchExecuteCall {
        let reference: [Any]
        switch group.id {
        case let .dmID(id): reference = ["dm/" + id.dmID, id.dmID, 5]
        case let .spaceID(id): reference = ["space/" + id.spaceID, id.spaceID, 2]
        case nil: throw Failure.invalidGroup
        }
        guard let id = reference[1] as? String, !id.isEmpty, id.utf8.count <= 128 else {
            throw Failure.invalidGroup
        }
        let bytes = try JSONSerialization.data(
            withJSONObject: [reference, [1]], options: [.withoutEscapingSlashes]
        )
        return BatchExecuteCall(
            rpc: rpc, payload: String(decoding: bytes, as: UTF8.self), sourcePath: "/app"
        )
    }

    /// Response1 contains participant IDs1, total count2 and anonymous people4.
    /// Missing/malformed content is not an authoritative empty roster.
    public static func participants(from payload: String) throws -> Participants {
        guard payload.utf8.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any],
              let data = root.first as? [Any], data.count >= 2,
              let count = data[1] as? NSNumber,
              String(cString: count.objCType) != "c",
              count.doubleValue == Double(count.intValue), (0 ... 10000).contains(count.intValue)
        else { throw Failure.malformedParticipants }
        let people = try rows(data[0])
        var ids: [String] = []
        for person in people {
            guard let id = person.first as? String, !id.isEmpty, id.utf8.count <= 128 else {
                throw Failure.malformedParticipants
            }
            ids.append(id)
        }
        let anonymous = try data.count > 3 ? rows(data[3]) : []
        let names = try anonymous.map { person -> String? in
            guard let value = person.first, !(value is NSNull) else { return nil }
            guard let name = value as? String, name.utf8.count <= 1024 else {
                throw Failure.malformedParticipants
            }
            return name.isEmpty ? nil : name
        }
        guard Set(ids).count == ids.count, ids.count + names.count <= count.intValue else {
            throw Failure.malformedParticipants
        }
        return Participants(memberIDs: ids, anonymousNames: names, totalCount: count.intValue)
    }

    private static func rows(_ value: Any) throws -> [[Any]] {
        if value is NSNull {
            return []
        }
        guard let rows = value as? [[Any]], rows.count <= 256 else {
            throw Failure.malformedParticipants
        }
        return rows
    }
}
