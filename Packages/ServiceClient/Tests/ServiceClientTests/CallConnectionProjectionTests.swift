import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

struct CallConnectionProjectionTests {
    @Test func anUnchangedHealthySnapshotClearsTheConnectionFailureOnceWithoutReplayingTheCall() throws {
        var projection = ServiceCallStateProjection()
        let state = ServiceCallState(version: UUID().uuidString + ":1", isListening: true, call: .init(
            id: UUID(), recipient: .init(
                conversationID: .init("dm"),
                memberID: .init("peer"),
                displayName: "Peer"
            ),
            direction: .incoming, phase: .incoming
        ))
        _ = try projection.accept(state)
        for _ in 0 ..< 3 {
            #expect(projection.connectionFailed() == [.listenerChanged(isListening: false)])
            #expect(projection.connectionFailed().isEmpty)
            #expect(try projection.accept(state) == [.listenerChanged(isListening: true)])
            #expect(try projection.accept(state).isEmpty)
        }
    }

    @Test func readRecoveryKeepsActualProviderFailureAndPendingStartup() throws {
        for starting in [false, true] {
            var projection = ServiceCallStateProjection()
            let state = ServiceCallState(version: UUID().uuidString + ":1", isListenerStarting: starting)
            _ = try projection.accept(state)
            _ = projection.connectionFailed()
            #expect(try projection.accept(state) == (starting ? [] : [.listenerChanged(isListening: false)]))
            #expect(try projection.accept(state).isEmpty)
        }
    }

    @Test func recoveryUsesTheNewestStateInsteadOfAnOlderSuccessfulReply() throws {
        var projection = ServiceCallStateProjection()
        let stream = UUID().uuidString
        let healthy = ServiceCallState(version: stream + ":1", isListening: true)
        _ = try projection.accept(healthy)
        _ = try projection.accept(.init(version: stream + ":2"))
        _ = projection.connectionFailed()
        #expect(try projection.accept(healthy) == [.listenerChanged(isListening: false)])
        #expect(projection.currentState?.isListening == false)
        #expect(projection.version == stream + ":2")
    }
}
