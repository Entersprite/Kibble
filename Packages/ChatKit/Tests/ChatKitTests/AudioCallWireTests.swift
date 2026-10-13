import Foundation
import Testing
@testable import ChatKit

struct AudioCallWireTests {
    private var recipient: AudioCallRecipient {
        AudioCallRecipient(
            conversationID: Conversation.ID("opaque-dm"),
            memberID: Member.ID("peer"),
            displayName: "Peer"
        )
    }

    @Test func eventsHaveStableProviderNeutralWireShapes() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        try expectWireStable(AudioCallEvent.recipientsChanged([recipient]), golden: "audio-call-recipients")
        try expectWireStable(
            AudioCallEvent.listenerChanged(isListening: false),
            golden: "audio-call-listener"
        )
        try expectWireStable(AudioCallEvent.snapshot(AudioCallSnapshot(
            id: id, recipient: recipient, direction: .incoming, phase: .incoming
        )), golden: "audio-call-incoming")
    }

    @Test func unknownEventAndStatusesSurviveNewerPeers() throws {
        let event = try Wire.decode(AudioCallEvent.self, from: #"{"type":"newAudioEvent"}"#)
        #expect(event == .unknown("newAudioEvent"))
        #expect(try Wire.json(event) == #"{"type":"newAudioEvent"}"#)
        let phase = try Wire.decode(AudioCallPhase.self, from: #""transferring""#)
        #expect(phase == .unknown("transferring"))
        #expect(phase.isTerminal)
        #expect(try Wire.json(phase) == #""transferring""#)
        let direction = try Wire.decode(AudioCallDirection.self, from: #""forwarded""#)
        #expect(direction == .unknown("forwarded"))
        #expect(try Wire.json(direction) == #""forwarded""#)
    }

    @Test func omittedMuteAndFailureAssumeLess() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-000000000001",
         "recipient":{"conversationID":"dm","memberID":"peer","displayName":"Peer"},
         "direction":"outgoing","phase":"ringing"}
        """#
        let call = try Wire.decode(AudioCallSnapshot.self, from: json)
        #expect(!call.isMuted)
        #expect(call.failureMessage == nil)
    }

    @Test func everyPhaseAndDirectionRoundTrips() throws {
        let phases: [AudioCallPhase] = [
            .incoming, .connecting, .ringing, .connected, .failed, .ended, .declined, .unknown("future")
        ]
        for phase in phases {
            #expect(try Wire.decode(AudioCallPhase.self, from: Wire.json(phase)) == phase)
        }
        for direction in [AudioCallDirection.incoming, .outgoing, .unknown("future")] {
            #expect(try Wire.decode(AudioCallDirection.self, from: Wire.json(direction)) == direction)
        }
    }
}
