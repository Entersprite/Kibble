import Foundation

/// Current Meet activity wire. Builders do not send requests. Resource names
/// must come from the same joined meeting's confirmed collection.
public enum MeetActivityWire {
    public struct Request: Sendable {
        public let method: String
        public let body: Data
        func validateScope(_ space: String) throws {
            let name: String = if [
                "MeetingSpaceService/UpdateMeetingSpace",
                "MeetingPollService/UpdatePoll",
                "MeetingQuestionService/UpdateQuestion"
            ].contains(method) {
                try MeetProto.text(1, MeetProto.payload(1, body))
            } else {
                try MeetProto.text(1, body)
            }
            guard name == space || name.hasPrefix(space + "/")
            else { throw MeetCallWire.WireError.invalidIdentifier }
        }
    }

    public static func artifact(
        space: String,
        kind: String,
        start: Bool,
        session: String?,
        requestID: UUID
    ) throws -> Request {
        let fields: [String: (UInt64, String)] = [
            "recording": (20, "recording_session_info"),
            "transcription": (17, "transcription_session_info"),
            "notes": (29, "smart_notes_session_info")
        ]
        guard let (field, path) = fields[kind] else { throw MeetCallWire.WireError.invalidIdentifier }
        var info = MeetProto.bytes(2, MeetProto.number(1, start ? 1 : 3))
        if !start {
            guard let session, !session.isEmpty, session.utf8.count <= 512 else {
                throw MeetCallWire.WireError.invalidIdentifier
            }
            info = MeetProto.string(1, session) + info
        }
        let mask = "call_info." + path + (start ? "" : ".session_state_info.session_state")
        return try updateSpace(
            space,
            callInfo: MeetProto.bytes(field, info),
            mask: mask,
            requestID: requestID
        )
    }

    public static func attendance(space: String, enabled: Bool, requestID: UUID) throws -> Request {
        try updateSpace(
            space,
            callInfo: MeetProto.bytes(11, MeetProto.number(4, enabled ? 1 : 0)),
            mask: "call_info.settings.attendance_report_enabled",
            requestID: requestID
        )
    }

    private static func updateSpace(
        _ space: String,
        callInfo: Data,
        mask: String,
        requestID: UUID
    ) throws -> Request {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        return Request(
            method: "MeetingSpaceService/UpdateMeetingSpace",
            body:
            MeetProto.bytes(1, MeetProto.string(1, space) + MeetProto.bytes(6, callInfo))
                + MeetProto.bytes(2, MeetProto.string(1, mask)) + MeetProto.string(3, requestID.uuidString)
        )
    }

    public static func createPoll(
        parent: String,
        title: String,
        options: [String],
        sequence _: UInt64
    ) throws -> Request {
        try validateText(title, maximum: 1000)
        guard options.count >= 2, options.count <= 10 else { throw MeetCallWire.WireError.invalidIdentifier }
        var question = MeetProto.string(1, title)
        for option in options {
            try validateText(option, maximum: 1000); question += MeetProto.bytes(
                2,
                MeetProto.string(1, option)
            )
        }
        let poll = MeetProto.number(3, 2) + MeetProto.number(5, 2) + MeetProto.number(6, 1)
            + MeetProto.bytes(4, MeetProto.bytes(1, question))
        return try create("MeetingPollService/CreatePoll", parent: parent, value: poll)
    }

    /// Native Meet sends the complete editable poll, without a field mask.
    /// Copy current title/options/state/privacy; never reconstruct it from UI text.
    public static func updatePoll(
        _ current: Data, open: Bool? = nil, resultsVisible: Bool? = nil
    ) throws -> Request {
        let name = try MeetProto.text(1, current)
        try resource(name)
        let state = try MeetProto.value(3, current)
        let visibility = try MeetProto.value(5, current)
        let anonymity = try MeetProto.value(6, current)
        guard (1 ... 3).contains(state), (1 ... 2).contains(visibility), (1 ... 2).contains(anonymity)
        else { throw MeetCallWire.WireError.malformedResponse }
        var poll = MeetProto.string(1, name)
            + MeetProto.number(3, open.map { $0 ? 2 : 3 } ?? state)
            + MeetProto.number(5, resultsVisible.map { $0 ? 1 : 2 } ?? visibility)
            + MeetProto.number(6, anonymity)
        for question in ProtoFieldScan.payloads(ofField: 4, in: current) {
            poll += MeetProto.bytes(4, question)
        }
        return Request(method: "MeetingPollService/UpdatePoll", body: MeetProto.bytes(1, poll))
    }

    public static func votePoll(_ name: String, option: String) throws -> Request {
        try resource(name)
        try validateText(option, maximum: 1000)
        return Request(
            method: "MeetingPollService/SubmitPollAnswer",
            body:
            MeetProto.string(1, name) + MeetProto.bytes(2, MeetProto.string(1, option))
        )
    }

    public static func createQuestion(
        parent: String,
        text: String,
        anonymous: Bool,
        sequence: UInt64
    ) throws -> Request {
        try validateText(text, maximum: 4000)
        return try create(
            "MeetingQuestionService/CreateQuestion",
            parent: parent,
            value:
            MeetProto.number(2, sequence) + MeetProto.string(4, text) + MeetProto.number(6, 1) + MeetProto
                .number(
                    7,
                    1
                )
                + MeetProto.number(11, anonymous ? 1 : 0)
        )
    }

    public static func voteQuestion(_ name: String, voted: Bool) throws -> Request {
        try resource(name)
        return Request(
            method: "MeetingQuestionService/CastQuestionVote",
            body:
            MeetProto.string(1, name) + MeetProto.number(2, voted ? 1 : 2)
        )
    }

    public static func answerQuestion(_ current: Data) throws -> Request {
        try resource(MeetProto.text(1, current))
        guard let preserved = ProtoFieldScan.removingVarint(7, from: current) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        // Native Meet clones the current question and changes AnswerState (7),
        // leaving visibility State (6) and unknown fields intact, without a mask.
        return Request(
            method: "MeetingQuestionService/UpdateQuestion",
            body: MeetProto.bytes(1, preserved + MeetProto.number(7, 2))
        )
    }

    public static func initializeRooms(space: String) throws -> Request {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        return Request(
            method: "MeetingBreakoutStateService/InitializeBreakoutState",
            body: MeetProto.string(1, space)
        )
    }

    public static func configureRooms(
        space: String,
        open: Bool,
        names: [String],
        sequence: UInt64
    ) throws -> Request {
        guard MeetDeviceWire.validSpace(space), names.count <= 100 else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        var body = MeetProto.string(1, space) + MeetProto.number(2, open ? 1 : 2)
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

    public static func assignRoom(space: String, room: String, people: [String]) throws -> Request {
        guard MeetDeviceWire.validSpace(space), room.hasPrefix(space + "/"), people.count <= 256,
              people.allSatisfy({ $0.hasPrefix(space + "/") })
        else { throw MeetCallWire.WireError.invalidIdentifier }
        try resource(room)
        var update = MeetProto.bytes(1, MeetProto.string(1, room))
        for person in people {
            try resource(person); update += MeetProto.string(3, person)
        }
        return Request(
            method: "MeetingBreakoutStateService/ConfigureBreakoutSessions",
            body: MeetProto.string(1, space) + MeetProto.bytes(5, update)
        )
    }

    private static func create(_ method: String, parent: String, value: Data) throws -> Request {
        try resource(parent)
        return Request(method: method, body: MeetProto.string(1, parent) + MeetProto.bytes(2, value))
    }

    static func resource(_ name: String) throws {
        guard name.hasPrefix("spaces/"), name.utf8.count <= 512,
              !name.contains(".."), !name.contains("?"), !name.contains("#"),
              name.utf8.allSatisfy({ (33 ... 126).contains($0) })
        else { throw MeetCallWire.WireError.invalidIdentifier }
    }

    static func validateText(_ text: String, maximum: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximum,
              !text.contains("\0") else { throw MeetCallWire.WireError.invalidIdentifier }
    }
}
