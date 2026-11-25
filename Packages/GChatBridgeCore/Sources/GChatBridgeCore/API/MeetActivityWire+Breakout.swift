import Foundation

public extension MeetActivityWire {
    static func initializeRooms(space: String) throws -> Request {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        return Request(
            method: "MeetingBreakoutStateService/InitializeBreakoutState",
            body: MeetProto.string(1, space)
        )
    }

    enum BreakoutStatus: UInt64, Sendable {
        case closed = 1, open = 2, closing = 3
    }

    static func configureRooms(
        space: String,
        open: Bool,
        names: [String],
        sequence: UInt64
    ) throws -> Request {
        guard MeetDeviceWire.validSpace(space), names.count <= 100 else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let status: BreakoutStatus = open ? .open : .closed
        var body = MeetProto.string(1, space) + MeetProto.number(2, status.rawValue)
        if !names.isEmpty {
            for (index, name) in names.enumerated() {
                try validateText(name, maximum: 100)
                let room = MeetProto.string(3, name)
                body += MeetProto.bytes(
                    4,
                    MeetProto.bytes(1, room) + MeetProto.number(2, sequence + UInt64(index))
                )
            }
        }
        return Request(method: "MeetingBreakoutStateService/ConfigureBreakoutSessions", body: body)
    }

    static func assignRoom(
        space: String, room: String, people: [String], unassigning: [String] = []
    ) throws -> Request {
        let affected = people + unassigning
        guard MeetDeviceWire.validSpace(space), validBreakoutRoom(room, in: space), affected.count <= 256,
              affected.allSatisfy({ $0.hasPrefix(space + "/") }), Set(people).isDisjoint(with: unassigning)
        else { throw MeetCallWire.WireError.invalidIdentifier }
        for person in affected {
            try resource(person)
        }
        var body = MeetProto.string(1, space)
        for person in unassigning {
            body += MeetProto.string(3, person)
        }
        if !people.isEmpty || unassigning.isEmpty {
            var update = MeetProto.bytes(1, MeetProto.string(1, room))
            for person in people {
                update += MeetProto.string(3, person)
            }
            body += MeetProto.bytes(5, update)
        }
        return Request(method: "MeetingBreakoutStateService/ConfigureBreakoutSessions", body: body)
    }

    internal static func validBreakoutRoom(_ name: String, in space: String) -> Bool {
        // A current Meet room uses a bare UUID inside the meeting-scoped collection.
        if name.utf8.count == 36, UUID(uuidString: name) != nil {
            return true
        }
        return name.hasPrefix(space + "/") && (try? resource(name)) != nil
    }
}
