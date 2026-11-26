import Foundation

/// Current Meet activity wire. Builders do not send requests. Resource names
/// must come from the same joined meeting's confirmed collection.
public enum MeetActivityWire {
    public struct Request: Sendable {
        public let method: String
        public let body: Data
        func validateScope(_ space: String, observed: MeetActivityCollections.Snapshot? = nil) throws {
            let name: String = if [
                "MeetingSpaceService/UpdateMeetingSpace",
                "MeetingPollService/UpdatePoll",
                "MeetingQuestionService/UpdateQuestion"
            ].contains(method) {
                try MeetProto.text(1, MeetProto.payload(1, body))
            } else {
                try MeetProto.text(1, body)
            }
            if name == space || name.hasPrefix(space + "/") {
                return
            }
            let field: Int? = switch method {
            case "MeetingPollService/UpdatePoll", "MeetingPollService/SubmitPollAnswer": 4
            case "MeetingPollService/CreatePoll": 5
            case "MeetingQuestionService/UpdateQuestion", "MeetingQuestionService/CastQuestionVote": 6
            case "MeetingQuestionService/CreateQuestion": 7
            default: nil
            }
            guard let field, observed?.containsGlobalResource(name, field: field, space: space) == true else {
                throw MeetCallWire.WireError.invalidIdentifier
            }
        }
    }

    public static func artifact(
        space: String,
        kind: String,
        start: Bool,
        session: String?,
        requestID: UUID,
        recordingCaptionLanguage: String? = nil
    ) throws -> Request {
        let fields: [String: (UInt64, String)] = [
            "recording": (20, "recording_session_info"),
            "transcription": (17, "transcription_session_info"),
            "notes": (29, "smart_notes_session_info")
        ]
        guard let (field, path) = fields[kind] else { throw MeetCallWire.WireError.invalidIdentifier }
        var state = MeetProto.number(1, start ? 1 : 3)
        if let recordingCaptionLanguage {
            guard kind == "recording", start, MeetCaptionWire.validLanguage(recordingCaptionLanguage)
            else { throw MeetCallWire.WireError.invalidIdentifier }
            state += MeetProto.bytes(6, MeetProto.string(1, recordingCaptionLanguage))
        }
        var info = MeetProto.bytes(2, state)
        if recordingCaptionLanguage != nil {
            info += MeetProto.number(4, 1)
        }
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
            mask: [mask],
            requestID: requestID
        )
    }

    public static func recordingCaptionLanguage(in session: Data) -> String? {
        guard (try? MeetProto.value(4, session)) == 1,
              let state = try? MeetProto.payload(2, session),
              let languages = try? MeetProto.payload(6, state),
              let language = try? MeetProto.text(1, languages), MeetCaptionWire.validLanguage(language)
        else { return nil }
        return language
    }

    public static func attendance(space: String, enabled: Bool, requestID: UUID) throws -> Request {
        try updateSpace(
            space,
            callInfo: MeetProto.bytes(11, MeetProto.number(4, enabled ? 1 : 0)),
            mask: ["call_info.settings.attendance_report_enabled"],
            requestID: requestID
        )
    }

    public enum HostSetting: Sendable {
        case management, reactions, chatMessages, screenSharing, microphone, camera
        case allowJoiningBeforeHost, allowJoinRequests
    }

    static func endConferenceBody(space: String) throws -> Data {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        return MeetProto.string(1, space)
    }

    public static func hostSetting(
        _ setting: HostSetting,
        space: String,
        enabled: Bool,
        requestID: UUID
    ) throws -> Request {
        let field: Data
        let paths: [String]
        let savedSettings: Data?
        switch setting {
        case .management:
            field = MeetProto.number(7, enabled ? 1 : 0)
            paths = ["call_info.settings.moderation_enabled"]
            savedSettings = nil
        case .reactions:
            field = MeetProto.number(9, enabled ? 0 : 1)
            paths = ["call_info.settings.reactions_lock"]
            savedSettings = nil
        case .chatMessages:
            let policy: UInt64 = enabled ? 2 : 3
            field = MeetProto.number(38, policy)
            paths = ["call_info.settings.send_chat_lock", "settings.send_chat_lock"]
            savedSettings = MeetProto.number(36, policy)
        case .screenSharing:
            let locked: UInt64 = enabled ? 0 : 1
            field = MeetProto.number(3, locked)
            paths = ["call_info.settings.present_lock", "settings.present_lock"]
            savedSettings = MeetProto.number(4, locked)
        case .microphone:
            field = MeetProto.number(5, enabled ? 0 : 1)
            paths = ["call_info.settings.audio_lock"]
            savedSettings = nil
        case .camera:
            field = MeetProto.number(6, enabled ? 0 : 1)
            paths = ["call_info.settings.video_lock"]
            savedSettings = nil
        case .allowJoiningBeforeHost:
            // The active Boolean uses an omitted default; the saved Boolean has presence.
            field = enabled ? MeetProto.number(11, 1) : Data()
            paths = ["call_info.settings.allow_joining_before_host", "settings.allow_joining_before_host"]
            savedSettings = MeetProto.number(10, enabled ? 1 : 0)
        case .allowJoinRequests:
            let policy: UInt64 = enabled ? 2 : 1
            field = MeetProto.number(40, policy)
            paths = ["call_info.settings.knocking_setting", "settings.knocking_setting"]
            savedSettings = MeetProto.number(38, policy)
        }
        return try updateSpace(
            space, callInfo: MeetProto.bytes(11, field),
            mask: paths, requestID: requestID, savedSettings: savedSettings
        )
    }

    static func spaceSettings(in space: Data, saved: Bool) -> Data? {
        if saved {
            return try? MeetProto.payload(15, space)
        }
        return (try? MeetProto.payload(6, space)).flatMap { try? MeetProto.payload(11, $0) }
    }

    static func updateSpace(
        _ space: String,
        callInfo: Data,
        mask: [String],
        requestID: UUID,
        savedSettings: Data? = nil
    ) throws -> Request {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        var resource = MeetProto.string(1, space) + MeetProto.bytes(6, callInfo)
        if let savedSettings {
            resource += MeetProto.bytes(15, savedSettings)
        }
        let paths = mask.reduce(into: Data()) { $0 += MeetProto.string(1, $1) }
        return Request(
            method: "MeetingSpaceService/UpdateMeetingSpace",
            body: MeetProto.bytes(1, resource) + MeetProto.bytes(2, paths)
                + MeetProto.string(3, requestID.uuidString)
        )
    }

    public static func createPoll(
        parent: String,
        title: String,
        options: [String],
        sequence: UInt64
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
        let poll = MeetProto.number(2, sequence) + MeetProto.number(3, 2)
            + MeetProto.number(5, 2) + MeetProto.number(6, 1) + MeetProto.number(7, 1)
            + MeetProto.bytes(4, MeetProto.bytes(1, question))
        return try create("MeetingPollService/CreatePoll", parent: parent, value: poll, field: 5)
    }

    /// Native Meet sends the complete editable poll, without a field mask.
    /// Copy current title/options/state/privacy; never reconstruct it from UI text.
    public static func updatePoll(
        _ current: Data, open: Bool? = nil, resultsVisible: Bool? = nil
    ) throws -> Request {
        let name = try MeetProto.text(1, current)
        try activityResource(name, field: 4)
        let state = try MeetProto.value(3, current)
        let visibility = try MeetProto.value(5, current)
        let anonymity = try MeetProto.value(6, current)
        guard (1 ... 3).contains(state), (1 ... 2).contains(visibility), (1 ... 2).contains(anonymity)
        else { throw MeetCallWire.WireError.malformedResponse }
        var poll = MeetProto.string(1, name)
            + MeetProto.number(3, open.map { $0 ? 2 : 3 } ?? state)
            + MeetProto.number(5, resultsVisible.map { $0 ? 1 : 2 } ?? visibility)
            + MeetProto.number(6, anonymity)
        if MeetActivityCollections.has(7, current) {
            let option = try MeetProto.value(7, current)
            guard option <= 1 else { throw MeetCallWire.WireError.malformedResponse }
            poll += MeetProto.number(7, option)
        }
        for question in ProtoFieldScan.payloads(ofField: 4, in: current) {
            poll += MeetProto.bytes(4, question)
        }
        return Request(method: "MeetingPollService/UpdatePoll", body: MeetProto.bytes(1, poll))
    }

    public static func votePoll(_ name: String, option: String) throws -> Request {
        try activityResource(name, field: 4)
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
                + MeetProto.number(11, anonymous ? 1 : 0),
            field: 7
        )
    }

    public static func voteQuestion(_ name: String, voted: Bool) throws -> Request {
        try activityResource(name, field: 6)
        return Request(
            method: "MeetingQuestionService/CastQuestionVote",
            body:
            MeetProto.string(1, name) + MeetProto.number(2, voted ? 1 : 2)
        )
    }

    public static func answerQuestion(_ current: Data) throws -> Request {
        try activityResource(MeetProto.text(1, current), field: 6)
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

    private static func create(_ method: String, parent: String, value: Data, field: Int) throws -> Request {
        try activityResource(parent, field: field)
        return Request(method: method, body: MeetProto.string(1, parent) + MeetProto.bytes(2, value))
    }

    private static func activityResource(_ name: String, field: Int) throws {
        if MeetActivityCollections.isGlobalResource(name, field: field) {
            return
        }
        try resource(name)
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

public extension MeetActivityWire {
    static func continuousChatGroup(in space: Data) -> String? {
        guard let info = try? MeetProto.payload(6, space),
              let chat = try? MeetProto.payload(34, info),
              let id = try? MeetProto.text(1, chat), MeetDeviceWire.validSpace("spaces/" + id)
        else { return nil }
        return id
    }

    static func waitingRoomEnabled(in space: Data) -> Bool? {
        explicitSpaceSetting(in: space, field: 22, saved: false)
    }

    static func joiningBeforeHostAllowed(in space: Data, saved: Bool = false) -> Bool? {
        let savedPolicy = explicitSpaceSetting(in: space, field: 10, saved: true)
        if saved {
            return savedPolicy
        }
        if let active = explicitSpaceSetting(in: space, field: 11, saved: false) {
            return active
        }
        // Only infer the active default when the saved policy explicitly confirms it.
        guard savedPolicy == false, let settings = spaceSettings(in: space, saved: false) else { return nil }
        let fields = ProtoFieldScan.fields(in: settings)
        guard !fields.truncated, !fields.fields.contains(where: { $0.number == 11 }) else { return nil }
        return false
    }

    private static func explicitSpaceSetting(in space: Data, field: Int, saved: Bool) -> Bool? {
        guard let settings = spaceSettings(in: space, saved: saved),
              let value = try? MeetProto.value(field, settings), value <= 1 else { return nil }
        return value == 1
    }

    static func hostSettings(in space: Data) -> (managementEnabled: Bool, reactionsAllowed: Bool)? {
        guard let settings = spaceSettings(in: space, saved: false) else { return nil }
        let fields = ProtoFieldScan.fields(in: settings)
        guard !fields.truncated else { return nil }
        let management = fields.fields.contains { $0.number == 7 } ? try? MeetProto.value(7, settings) : 0
        let locked = fields.fields.contains { $0.number == 9 } ? try? MeetProto.value(9, settings) : 0
        guard let management, let locked, management <= 1, locked <= 1 else { return nil }
        return (management == 1, locked == 0)
    }

    static func chatSendingPolicy(
        in space: Data, saved: Bool = false, includingDefault: Bool = false
    ) -> Bool? {
        switch spaceSettings(in: space, saved: saved).flatMap({
            try? MeetProto.value(saved ? 36 : 38, $0)
        }) {
        case 1 where includingDefault: true
        case 2: true
        case 3: false
        default: nil
        }
    }

    static func screenSharingPolicy(in space: Data, saved: Bool = false) -> Bool? {
        captureAllowed(in: space, field: saved ? 4 : 3, saved: saved)
    }

    static func microphonePolicy(in space: Data) -> Bool? {
        captureAllowed(in: space, field: 5, saved: false)
    }

    static func cameraPolicy(in space: Data) -> Bool? {
        captureAllowed(in: space, field: 6, saved: false)
    }

    private static func captureAllowed(in space: Data, field: Int, saved: Bool) -> Bool? {
        guard let settings = spaceSettings(in: space, saved: saved) else { return nil }
        let fields = ProtoFieldScan.fields(in: settings)
        guard !fields.truncated else { return nil }
        let locked = fields.fields.contains { $0.number == field } ? try? MeetProto.value(field, settings) : 0
        return locked.flatMap { $0 <= 1 ? $0 == 0 : nil }
    }
}
