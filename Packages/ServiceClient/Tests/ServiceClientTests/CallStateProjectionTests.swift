import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

struct CallStateProjectionTests {
    @Test func startupDirectoryUpdatesDoNotReportAListenerFailure() throws {
        var projection = ServiceCallStateProjection()
        let stream = UUID().uuidString
        let initial = try projection.accept(.init(version: stream + ":0", isListenerStarting: true))
        #expect(initial == [.recipientsChanged([])])
        let recipient = AudioCallRecipient(
            conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
        )
        #expect(try projection.accept(.init(
            version: stream + ":1", isListenerStarting: true, recipients: [recipient]
        )) == [.recipientsChanged([recipient])])
        #expect(try projection.accept(.init(
            version: stream + ":2", isListening: true, recipients: [recipient]
        )) == [.listenerChanged(isListening: true)])
        #expect(try projection.accept(.init(
            version: stream + ":3", recipients: [recipient]
        )) == [.listenerChanged(isListening: false)])
    }

    @Test func aFailedFirstAttemptAndAFailedReplacementStillReportUnavailable() throws {
        var projection = ServiceCallStateProjection()
        let stream = UUID().uuidString
        _ = try projection.accept(.init(version: stream + ":0", isListenerStarting: true))
        #expect(try projection.accept(.init(version: stream + ":1")) == [
            .listenerChanged(isListening: false)
        ])
        let replacement = UUID().uuidString
        #expect(try projection.accept(.init(
            version: replacement + ":0", isListenerStarting: true
        )) == [.recipientsChanged([])])
        #expect(try projection.accept(.init(version: replacement + ":1")) == [
            .listenerChanged(isListening: false)
        ])
    }

    @Test func aLateControlReplyCannotRewindANewerObservedMuteState() throws {
        var projection = ServiceCallStateProjection()
        let stream = UUID()
        let id = UUID()
        _ = try projection.accept(state(stream, sequence: 1, id: id))
        _ = try projection.accept(state(stream, sequence: 3, id: id))
        #expect(try projection.accept(state(stream, sequence: 2, id: id, muted: true)).isEmpty)
        #expect(projection.version == stream.uuidString + ":3")
        #expect(throws: ServiceFailure.invalidResponse) {
            try projection.accept(state(stream, sequence: 3, id: id, muted: true))
        }
    }

    @Test func aReplacementStreamEndsOldPresentationAndFencesItsLateReplies() throws {
        var projection = ServiceCallStateProjection()
        let old = UUID(); let id = UUID(); let current = UUID()
        _ = try projection.accept(state(old, sequence: 1, id: id))
        let events = try projection.accept(.init(version: current.uuidString + ":0"))
        let ended = events.compactMap { event -> AudioCallSnapshot? in
            if case let .snapshot(call) = event {
                return call
            }
            return nil
        }
        #expect(ended.first?.id == id && ended.first?.phase == .failed)
        #expect(try projection.accept(state(old, sequence: 10, id: id)).isEmpty)
        #expect(projection.version == current.uuidString + ":0")
        let unknown = AudioCallEvent.unknown(type: "future", payload: .object([
            "type": .string("future"), "extra": .bool(true)
        ]))
        let retained = try projection.accept(.init(version: current.uuidString + ":1", lastEvent: unknown))
        #expect(retained == [unknown])
    }

    @Test func malformedPositionsCannotEstablishCallState() throws {
        for version in ["future", UUID().uuidString + ":01", UUID().uuidString + ":-1"] {
            var projection = ServiceCallStateProjection()
            #expect(throws: ServiceFailure.invalidResponse) { try projection.accept(.init(version: version)) }
            #expect(projection.version == nil)
        }
    }

    private func state(_ stream: UUID, sequence: Int, id: UUID, muted: Bool = false) -> ServiceCallState {
        .init(version: stream.uuidString + ":" + String(sequence), isListening: true, call: .init(
            id: id, recipient: .init(
                conversationID: .init("dm"),
                memberID: .init("peer"),
                displayName: "Peer"
            ),
            direction: .outgoing, phase: .connected, isMuted: muted
        ))
    }
}
