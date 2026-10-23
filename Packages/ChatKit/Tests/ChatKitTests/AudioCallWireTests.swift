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

    @Test func anUnknownCallEventRetainsNestedPayloadInsteadOfOnlyItsName() throws {
        let json = #"""
        {"type":"futureCallEvent","state":{"enabled":true,"count":7,"nothing":null},
         "items":["opaque",{"future":"retained"}],"newField":0.25}
        """#
        let event = try Wire.decode(AudioCallEvent.self, from: json)
        let payload = try Wire.decode(JSONValue.self, from: json)
        #expect(event == .unknown(type: "futureCallEvent", payload: payload))
        #expect(try Wire.decode(JSONValue.self, from: Wire.json(event)) == payload)
        #expect(try Wire.decode(AudioCallEvent.self, from: Wire.json(event)) == event)
    }

    @Test func listenerRecoveryBarrierRetainsItsExactToken() throws {
        let json = #"{"type":"listenerBarrier","token":"00000000-0000-0000-0000-000000000001"}"#
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let value = try Wire.decode(AudioCallEvent.self, from: json)
        #expect(value == .listenerBarrier(id))
        #expect(try Wire.decode(AudioCallEvent.self, from: Wire.json(value)) == value)
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
        #expect(call.endReason == nil)
        #expect(call.remoteMuted == nil)
    }

    @Test func remoteMicrophoneStateHasStableWireShapesAndAbsentMeansUnknown() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        var call = AudioCallSnapshot(id: id, recipient: recipient, direction: .outgoing, phase: .connected)
        // Unknown adds no key, so an older reader sees exactly the snapshot it knew.
        #expect(try !Wire.json(call).contains("remoteMuted"))
        call.remoteMuted = true
        try expectWireStable(AudioCallEvent.snapshot(call), golden: "audio-call-remote-muted")
        call.remoteMuted = false
        try expectWireStable(AudioCallEvent.snapshot(call), golden: "audio-call-remote-unmuted")
    }

    @Test func aNewerRemoteMicrophoneValueIsUnknownRatherThanAFailedSnapshot() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-000000000001",
         "recipient":{"conversationID":"dm","memberID":"peer","displayName":"Peer"},
         "direction":"outgoing","phase":"connected","isMuted":true,"remoteMuted":"partially"}
        """#
        let call = try Wire.decode(AudioCallSnapshot.self, from: json)
        #expect(call.remoteMuted == nil)
        #expect(call.isMuted)
        #expect(call.phase == .connected)
    }

    @Test func terminalReasonsHaveStableWireShapesAndPreserveNewerValues() throws {
        for (value, json) in [
            (AudioCallEndReason.localEnded, #""localEnded""#),
            (.remoteEnded, #""remoteEnded""#), (.declined, #""declined""#),
            (.unknown("futureCause"), #""futureCause""#)
        ] {
            #expect(try Wire.json(value) == json)
            #expect(try Wire.decode(AudioCallEndReason.self, from: json) == value)
        }
        var call = try AudioCallSnapshot(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            recipient: recipient, direction: .outgoing, phase: .ended
        )
        call.endReason = .remoteEnded
        try expectWireStable(AudioCallEvent.snapshot(call), golden: "audio-call-remote-ended")
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
