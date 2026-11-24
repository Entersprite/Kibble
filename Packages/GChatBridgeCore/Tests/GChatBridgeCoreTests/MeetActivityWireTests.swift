import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetActivityWireTests {
    @Test(arguments: [true, false])
    func screenSharingUsesTheDualLockFieldsAndMasks(allowed: Bool) throws {
        let request = try MeetActivityWire.hostSetting(
            .screenSharing, space: "spaces/demo", enabled: allowed, requestID: UUID()
        )
        let resource = try MeetProto.payload(1, request.body)
        let call = try MeetProto.payload(11, MeetProto.payload(6, resource))
        let saved = try MeetProto.payload(15, resource)
        #expect(ProtoFieldScan.fields(in: call).fields.map(\.number) == [3])
        #expect(ProtoFieldScan.fields(in: saved).fields.map(\.number) == [4])
        #expect(try MeetProto.value(3, call) == (allowed ? 0 : 1))
        #expect(try MeetProto.value(4, saved) == (allowed ? 0 : 1))
        let mask = try MeetProto.payload(2, request.body)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: mask) == [
            Data("call_info.settings.present_lock".utf8), Data("settings.present_lock".utf8)
        ])
        #expect(MeetActivityWire.screenSharingPolicy(in: resource) == allowed)
        #expect(MeetActivityWire.screenSharingPolicy(in: resource, saved: true) == allowed)
    }

    @Test func screenSharingDefaultsOnlyInsideAValidSettingsResource() {
        #expect(MeetActivityWire.screenSharingPolicy(in: Data()) == nil)
        let defaults = MeetProto.bytes(6, MeetProto.bytes(11, Data()))
        #expect(MeetActivityWire.screenSharingPolicy(in: defaults) == true)
        let invalid = MeetProto.bytes(6, MeetProto.bytes(11, MeetProto.number(3, 2)))
        #expect(MeetActivityWire.screenSharingPolicy(in: invalid) == nil)
    }

    @Test(arguments: [true, false])
    func hostChatWritingUpdatesBothScopesWithoutTouchingReceivePolicy(enabled: Bool) throws {
        let request = try MeetActivityWire.hostSetting(
            .chatMessages, space: "spaces/demo", enabled: enabled, requestID: UUID()
        )
        let resource = try MeetProto.payload(1, request.body)
        #expect(ProtoFieldScan.fields(in: resource).fields.map(\.number) == [1, 6, 15])
        let call = try MeetProto.payload(11, MeetProto.payload(6, resource))
        let saved = try MeetProto.payload(15, resource)
        #expect(ProtoFieldScan.fields(in: call).fields.map(\.number) == [38])
        #expect(ProtoFieldScan.fields(in: saved).fields.map(\.number) == [36])
        #expect(try MeetProto.value(38, call) == (enabled ? 2 : 3))
        #expect(try MeetProto.value(36, saved) == (enabled ? 2 : 3))
        let mask = try MeetProto.payload(2, request.body)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: mask) == [
            Data("call_info.settings.send_chat_lock".utf8), Data("settings.send_chat_lock".utf8)
        ])
        #expect(MeetActivityWire.chatSendingPolicy(in: resource) == enabled)
        #expect(MeetActivityWire.chatSendingPolicy(in: resource, saved: true) == enabled)
    }

    @Test func endConferenceNamesOnlyTheResolvedSpace() throws {
        let body = try MeetActivityWire.endConferenceBody(space: "spaces/demo")
        #expect(body == MeetProto.string(1, "spaces/demo"))
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetActivityWire.endConferenceBody(space: "spaces/demo/devices/other")
        }
    }

    @Test(arguments: [
        (MeetActivityWire.HostSetting.management, 7, "moderation_enabled", true, UInt64(1)),
        (.management, 7, "moderation_enabled", false, 0),
        (.reactions, 9, "reactions_lock", true, 0),
        (.reactions, 9, "reactions_lock", false, 1),
        (.microphone, 5, "audio_lock", true, 0),
        (.microphone, 5, "audio_lock", false, 1),
        (.camera, 6, "video_lock", true, 0),
        (.camera, 6, "video_lock", false, 1)
    ])
    func hostSettingWritesOnlyItsCallField(
        _ setting: MeetActivityWire.HostSetting, field: Int, mask: String, enabled: Bool, value: UInt64
    ) throws {
        let request = try MeetActivityWire.hostSetting(
            setting, space: "spaces/demo", enabled: enabled, requestID: UUID()
        )
        #expect(request.method == "MeetingSpaceService/UpdateMeetingSpace")
        let space = try MeetProto.payload(1, request.body)
        #expect(ProtoFieldScan.fields(in: space).fields.map(\.number) == [1, 6])
        #expect(try MeetProto.text(1, space) == "spaces/demo")
        let settings = try MeetProto.payload(11, MeetProto.payload(6, space))
        #expect(ProtoFieldScan.fields(in: settings).fields.map(\.number) == [field])
        #expect(try MeetProto.value(field, settings) == value)
        #expect(try MeetProto.text(1, MeetProto.payload(2, request.body)) == "call_info.settings." + mask)
    }

    @Test(arguments: [1, 2, 4, 5, 6, 999])
    func onlyKnownProviderRolesAreHosts(_ role: UInt64) throws {
        let value = MeetProto.string(1, "spaces/demo/devices/one") + MeetProto.number(4, 1)
            + MeetProto.number(46, role)
        let device = try MeetDeviceWire.devicePayload(value, in: "spaces/demo")
        #expect(device.hasHostRole == (role == 1 || role == 5))
    }

    @Test func recordingStartEncodesItsRequestedCaptionLanguageAndFlag() throws {
        let request = try MeetActivityWire.artifact(
            space: "spaces/demo", kind: "recording", start: true, session: nil,
            requestID: UUID(), recordingCaptionLanguage: "fr-FR"
        )
        let space = try MeetProto.payload(1, request.body)
        let session = try MeetProto.payload(20, MeetProto.payload(6, space))
        let state = try MeetProto.payload(2, session)
        #expect(ProtoFieldScan.fields(in: session).fields.map(\.number) == [2, 4])
        #expect(try MeetProto.value(4, session) == 1)
        #expect(try MeetProto.text(1, MeetProto.payload(6, state)) == "fr-FR")
        #expect(MeetActivityWire.recordingCaptionLanguage(in: session) == "fr-FR")
        let mask = try MeetProto.text(1, MeetProto.payload(2, request.body))
        #expect(mask == "call_info.recording_session_info")
    }

    @Test(arguments: [
        ("recording", false, "fr-FR"),
        ("transcription", true, "fr-FR"),
        ("recording", true, "x/")
    ])
    func recordingCaptionOptionsCannotAffectOtherWrites(kind: String, start: Bool, language: String) {
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityWire.artifact(
                space: "spaces/demo", kind: kind, start: start, session: "confirmed-session",
                requestID: UUID(), recordingCaptionLanguage: language
            )
        }
    }

    @Test(arguments: [("recording", 20), ("transcription", 17), ("notes", 29)])
    func artifactWritesOnlyItsAddressedSessionAndMask(_ kind: String, _ field: Int) throws {
        let request = try MeetActivityWire.artifact(
            space: "spaces/demo",
            kind: kind,
            start: false,
            session: "confirmed-session",
            requestID: UUID()
        )
        #expect(request.method == "MeetingSpaceService/UpdateMeetingSpace")
        let space = try MeetProto.payload(1, request.body)
        #expect(try MeetProto.text(1, space) == "spaces/demo")
        let call = try MeetProto.payload(6, space)
        #expect(ProtoFieldScan.fields(in: call).fields.map(\.number) == [field])
        let session = try MeetProto.payload(field, call)
        #expect(try MeetProto.text(1, session) == "confirmed-session")
        #expect(try MeetProto.value(1, MeetProto.payload(2, session)) == 3)
        let mask = try MeetProto.text(1, MeetProto.payload(2, request.body))
        #expect(mask.hasSuffix(".session_state_info.session_state"))
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityWire.artifact(
                space: "spaces/demo",
                kind: kind,
                start: false,
                session: nil,
                requestID: UUID()
            )
        }
    }

    @Test func pollVotesCarryTheSelectedAnswerTextAndNeverInventAnIndexField() throws {
        let request = try MeetActivityWire.votePoll("spaces/demo/polls/one", option: "Second choice")
        #expect(request.method == "MeetingPollService/SubmitPollAnswer")
        #expect(try MeetProto.text(1, MeetProto.payload(2, request.body)) == "Second choice")
        let poll = try MeetActivityWire.createPoll(
            parent: "spaces/demo/pollSeries/one",
            title: "Choose",
            options: ["One", "Two"],
            sequence: 7
        )
        let value = try MeetProto.payload(2, poll.body)
        #expect(!MeetActivityCollections.has(2, value))
        #expect(try MeetProto.value(3, value) == 2)
        let question = try MeetProto.payload(1, MeetProto.payload(4, value))
        #expect(try MeetProto.text(1, question) == "Choose")
        #expect(ProtoFieldScan.payloads(ofField: 2, in: question).count == 2)
    }

    @Test func pollUpdatesPreserveCurrentEditableFieldsWithoutInventingAMask() throws {
        let question = MeetProto.bytes(1, MeetProto.string(1, "Choose"))
        let poll = MeetProto.string(1, "spaces/demo/polls/one") + MeetProto.number(3, 2)
            + MeetProto.number(5, 2) + MeetProto.number(6, 2) + MeetProto.bytes(4, question)
        let request = try MeetActivityWire.updatePoll(poll, resultsVisible: true)
        #expect(ProtoFieldScan.fields(in: request.body).fields.map(\.number) == [1])
        let updated = try MeetProto.payload(1, request.body)
        #expect(try MeetProto.value(3, updated) == 2)
        #expect(try MeetProto.value(5, updated) == 1)
        #expect(try MeetProto.value(6, updated) == 2)
        #expect(try MeetProto.payload(4, updated) == question)
        #expect(throws: MeetCallWire.WireError.self) { try request.validateScope("spaces/other") }
    }

    @Test func foreignBreakoutResourcesCannotBecomeJoinTargets() throws {
        func snapshot(_ name: String) -> Data {
            let room = MeetProto.string(1, name) + MeetProto.string(3, "One")
            let full = MeetProto.bytes(1, MeetProto.number(1, 1))
                + MeetProto.bytes(2, MeetProto.bytes(4, room))
            return Data(MeetProto.bytes(8, MeetProto.bytes(2, full)).base64EncodedString().utf8)
        }
        let own = try MeetActivityCollections.decode(snapshot("spaces/demo/rooms/one"), space: "spaces/demo")
        #expect(own.breakout != nil && own.versions[8] == 1)
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityCollections.decode(snapshot("spaces/foreign/rooms/one"), space: "spaces/demo")
        }
    }

    @Test func answeringAQuestionPreservesVisibilityAndFutureFields() throws {
        let current = MeetProto.string(1, "spaces/demo/questionSeries/one/questions/one")
            + MeetProto.string(4, "Why?") + MeetProto.number(6, 1) + MeetProto.number(7, 1)
            + MeetProto.bytes(200, Data([1, 2, 3]))
        let request = try MeetActivityWire.answerQuestion(current)
        #expect(ProtoFieldScan.fields(in: request.body).fields.map(\.number) == [1])
        let changed = try MeetProto.payload(1, request.body)
        #expect(try MeetProto.value(6, changed) == 1)
        #expect(try MeetProto.value(7, changed) == 2)
        #expect(try MeetProto.text(4, changed) == "Why?")
        #expect(try MeetProto.payload(200, changed) == Data([1, 2, 3]))
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityWire.answerQuestion(current + MeetProto.number(7, 1))
        }
    }

    @Test func reactionFramesAndChatAcknowledgementsHaveDistinctEnvelopes() throws {
        let sent = try MeetActivityDataWire.reaction("👍", sequence: 1)
        #expect(sent == Data([10, 12, 8, 1, 18, 8, 10, 6, 10, 4, 240, 159, 145, 141]))
        #expect(throws: MeetCallWire.WireError.self) { try MeetActivityDataWire.reaction(
            "not an emoji",
            sequence: 1
        ) }
        let entry = MeetProto.bytes(1, MeetProto.string(1, "👍"))
            + MeetProto.bytes(6, MeetProto.string(1, "device") + MeetProto.string(2, "Taylor"))
        let reactions = try MeetActivityDataWire.reactions(MeetProto.bytes(1, MeetProto.bytes(1, entry)))
        #expect(reactions.first?.displayName == "Taylor")
        let response = MeetProto.bytes(1, MeetProto.number(1, 2) + MeetProto.bytes(2, MeetProto.number(1, 7)))
        #expect(MeetActivityDataWire.isChatResponse(response, sequence: 2))
        #expect(!MeetActivityDataWire.isChatResponse(response, sequence: 3))
        let sameSequence = MeetProto.bytes(1, MeetProto.number(1, 2))
        #expect(!MeetActivityDataWire.isChatResponse(sameSequence, sequence: 2))
        let malformedStatus = MeetProto.bytes(
            1,
            MeetProto.number(1, 2)
                + MeetProto.bytes(2, MeetProto.string(1, "invalid"))
        )
        #expect(!MeetActivityDataWire.isChatResponse(malformedStatus, sequence: 2))
        #expect(throws: MeetActivityDataWire.MessageError.self) { try MeetActivityDataWire.chatResponse(
            response,
            sequence: 2
        ) }
        let request = try MeetActivityDataWire.chat("hello", sequence: 2)
        let message = try MeetProto.payload(
            2,
            MeetProto.payload(1, MeetProto.payload(3, MeetProto.payload(1, request)))
        )
        #expect(try MeetProto.text(1, MeetProto.payload(5, message)) == "hello")
    }

    @Test func meetingChatUsesOnlyAnUnambiguousPublicRecipient() {
        let text = MeetProto.number(6, 1)
        let publicRecipient = MeetProto.number(10, 0)
        for fields in [Data(), publicRecipient, MeetProto.number(10, 1), MeetProto.number(10, 4)] {
            #expect(MeetActivityDataWire.isPublicChatText(text + fields))
            #expect(MeetActivityDataWire.publicChatPin(in: text + fields) == false)
        }
        let otherRecipients = [2, 3, 5, 99].map { MeetProto.number(10, UInt64($0)) }
        let invalid = [MeetProto.string(10, "0"), publicRecipient + publicRecipient]
        for fields in otherRecipients + invalid {
            #expect(!MeetActivityDataWire.isPublicChatText(text + fields))
            #expect(MeetActivityDataWire.publicChatPin(in: text + fields) == nil)
        }
        #expect(!MeetActivityDataWire.isPublicChatText(MeetProto.number(6, 2) + publicRecipient))
    }

    @Test func aPinReceiptForAnotherAudienceCannotConfirmAnOrdinaryPin() throws {
        let message = MeetProto.string(1, "message-one") + MeetProto.number(7, 1)
        func receipt(_ row: Data) -> Data {
            let update = MeetProto.bytes(1, row) + MeetProto.string(5, "2-5")
            return MeetProto.bytes(
                1,
                MeetProto.number(1, 1) + MeetProto.bytes(2, Data()) + MeetProto.bytes(5, update)
            )
        }
        #expect(try MeetActivityDataWire.chatPinRevision(
            receipt(message), sequence: 1, name: "message-one", pinned: true
        ) == 2)
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetActivityDataWire.chatPinRevision(
                receipt(message + MeetProto.number(10, 2)), sequence: 1, name: "message-one", pinned: true
            )
        }
    }

    @Test func absentActivityCollectionsAreUnknownAndForeignSpaceIsRejected() throws {
        let full = MeetProto.bytes(1, MeetProto.number(1, 9))
            + MeetProto.bytes(2, MeetProto.string(1, "spaces/foreign"))
        let body = Data(MeetProto.bytes(1, MeetProto.bytes(2, full)).base64EncodedString().utf8)
        #expect(throws: MeetCallWire.WireError.self) { try MeetActivityCollections.decode(
            body,
            space: "spaces/demo"
        ) }
        let absent = try MeetActivityCollections.decode(Data(), space: "spaces/demo")
        #expect(absent.space == nil && absent.messages == nil && absent.polls == nil && absent.versions
            .isEmpty)
        let rooms = try MeetActivityWire.configureRooms(
            space: "spaces/demo",
            open: true,
            names: [],
            sequence: 1
        )
        #expect(ProtoFieldScan.fields(in: rooms.body).fields.map(\.number) == [1, 2])
    }
}

extension MeetActivityWireTests {
    @Test(arguments: MeetActivityWire.AccessPreset.allCases)
    func accessPresetWritesOnlyTheActiveAndSavedEnum(_ preset: MeetActivityWire.AccessPreset) throws {
        let request = try MeetActivityWire.meetingAccessPreset(
            preset,
            space: "spaces/demo",
            requestID: UUID()
        )
        let space = try MeetProto.payload(1, request.body)
        let active = try MeetProto.payload(11, MeetProto.payload(6, space))
        let saved = try MeetProto.payload(15, space)
        let expected: UInt64 = switch preset {
        case .open: 1
        case .trusted: 2
        case .restricted: 3
        }
        #expect(request.method == "MeetingSpaceService/UpdateMeetingSpace")
        #expect(active == MeetProto.number(12, expected))
        #expect(saved == MeetProto.number(11, expected))
        #expect(try MeetProto.payload(2, request.body) == MeetProto.string(
            1,
            "call_info.settings.access_type"
        )
            + MeetProto.string(1, "settings.access_type"))
        #expect(MeetActivityWire.meetingAccessPreset(in: space) == preset)
        #expect(MeetActivityWire.meetingAccessPreset(in: space, saved: true) == preset)
    }

    @Test func structuredAccessOptionsTakePriorityOverTheLegacyList() {
        let legacy = MeetProto.number(27, 1) + MeetProto.bytes(27, Data([2, 3, 4]))
        #expect(MeetActivityWire.availableMeetingAccessPresets(in: MeetProto.bytes(6, legacy)) == [
            .open, .trusted, .restricted
        ])
        let blocked = MeetProto.bytes(51, MeetProto.number(1, 1) + MeetProto.number(2, 2))
        let allowed = MeetProto.bytes(51, MeetProto.number(1, 3) + MeetProto.number(2, 1))
        let unknown = MeetProto.bytes(51, MeetProto.number(1, 4) + MeetProto.number(2, 1))
        #expect(MeetActivityWire.availableMeetingAccessPresets(
            in: MeetProto.bytes(6, legacy + allowed + blocked + unknown)
        ) == [.restricted])
        #expect(MeetActivityWire.availableMeetingAccessPresets(in: MeetProto.bytes(
            6,
            legacy + allowed + allowed
        )).isEmpty)
        #expect(MeetActivityWire.availableMeetingAccessPresets(
            in: MeetProto.bytes(6, MeetProto.number(27, 1) + MeetProto.bytes(27, Data([128])))
        ).isEmpty)
    }

    @Test(arguments: [true, false])
    func hostFirstWritesOnlyTheActiveAndSavedAdmissionBooleans(_ allowsEarlierEntry: Bool) throws {
        let request = try MeetActivityWire.hostSetting(
            .allowJoiningBeforeHost, space: "spaces/demo", enabled: allowsEarlierEntry, requestID: UUID()
        )
        let space = try MeetProto.payload(1, request.body)
        let active = try MeetProto.payload(11, MeetProto.payload(6, space))
        let saved = try MeetProto.payload(15, space)
        #expect(request.method == "MeetingSpaceService/UpdateMeetingSpace")
        #expect(ProtoFieldScan.fields(in: active).fields.map(\.number) == [11])
        #expect(ProtoFieldScan.fields(in: saved).fields.map(\.number) == [10])
        #expect(try MeetProto.value(11, active) == (allowsEarlierEntry ? 1 : 0))
        #expect(try MeetProto.value(10, saved) == (allowsEarlierEntry ? 1 : 0))
        let mask = try MeetProto.payload(2, request.body)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: mask) == [
            Data("call_info.settings.allow_joining_before_host".utf8),
            Data("settings.allow_joining_before_host".utf8)
        ])
        #expect(MeetActivityWire.joiningBeforeHostAllowed(in: space) == allowsEarlierEntry)
        #expect(MeetActivityWire.joiningBeforeHostAllowed(in: space, saved: true) == allowsEarlierEntry)
        #expect(MeetActivityWire.waitingRoomEnabled(in: space) == nil)
    }

    @Test func hostFirstMissingAndMalformedValuesStayUnknown() {
        for settings in [Data(), MeetProto.number(11, 2), MeetProto.number(11, 0) + MeetProto.number(11, 1)] {
            let response = MeetProto.bytes(6, MeetProto.bytes(11, settings))
            #expect(MeetActivityWire.joiningBeforeHostAllowed(in: response) == nil)
        }
    }
}
