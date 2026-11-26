import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetPollQuestionWireTests {
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
        #expect(try MeetProto.value(2, value) == 7)
        #expect(try MeetProto.value(3, value) == 2)
        #expect(try MeetProto.value(7, value) == 1)
        let question = try MeetProto.payload(1, MeetProto.payload(4, value))
        #expect(try MeetProto.text(1, question) == "Choose")
        #expect(ProtoFieldScan.payloads(ofField: 2, in: question).count == 2)
    }

    @Test func pollUpdatesPreserveCurrentEditableFieldsWithoutInventingAMask() throws {
        let question = MeetProto.bytes(1, MeetProto.string(1, "Choose"))
        let poll = MeetProto.string(1, "spaces/demo/polls/one") + MeetProto.number(3, 2)
            + MeetProto.number(5, 2) + MeetProto.number(6, 2) + MeetProto.number(7, 1)
            + MeetProto.bytes(4, question)
        let request = try MeetActivityWire.updatePoll(poll, resultsVisible: true)
        #expect(ProtoFieldScan.fields(in: request.body).fields.map(\.number) == [1])
        let updated = try MeetProto.payload(1, request.body)
        #expect(try MeetProto.value(3, updated) == 2)
        #expect(try MeetProto.value(5, updated) == 1)
        #expect(try MeetProto.value(6, updated) == 2)
        #expect(try MeetProto.value(7, updated) == 1)
        #expect(try MeetProto.payload(4, updated) == question)
        #expect(throws: MeetCallWire.WireError.self) { try request.validateScope("spaces/other") }
    }

    @Test func globalPollAndQuestionNamesRequireAnExactSameMeetingRead() throws {
        func collection(_ field: UInt64, _ name: String) -> Data {
            let full = MeetProto.bytes(1, MeetProto.number(1, 1))
                + MeetProto.bytes(2, MeetProto.string(1, name))
            return MeetProto.bytes(field, MeetProto.bytes(2, full))
        }
        let space = "spaces/demo"
        let pollSeries = "pollSeries/current"
        let questionSeries = "questionSeries/current"
        let poll = pollSeries + "/polls/first"
        let question = questionSeries + "/questions/first"
        let body = collection(4, poll) + collection(5, pollSeries)
            + collection(6, question) + collection(7, questionSeries)
        let observed = try MeetActivityCollections.decode(Data(body.base64EncodedString().utf8), space: space)
        let requests = try [
            MeetActivityWire.votePoll(poll, option: "First"),
            MeetActivityWire.createPoll(
                parent: pollSeries,
                title: "Choose",
                options: ["First", "Second"],
                sequence: 1
            ),
            MeetActivityWire.voteQuestion(question, voted: true),
            MeetActivityWire.createQuestion(
                parent: questionSeries,
                text: "Why?",
                anonymous: false,
                sequence: 1
            )
        ]
        for request in requests {
            try request.validateScope(space, observed: observed)
            #expect(throws: MeetCallWire.WireError.self) { try request.validateScope(space) }
            #expect(throws: MeetCallWire.WireError.self) { try request.validateScope(
                "spaces/other",
                observed: observed
            ) }
        }
        let unrelated = try MeetActivityWire.votePoll(pollSeries + "/polls/unseen", option: "First")
        #expect(throws: MeetCallWire.WireError.self) { try unrelated.validateScope(space, observed: observed)
        }
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityCollections.decode(
                Data(collection(4, question).base64EncodedString().utf8),
                space: space
            )
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
}
