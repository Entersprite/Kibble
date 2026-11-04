import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetActivityWireTests {
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
