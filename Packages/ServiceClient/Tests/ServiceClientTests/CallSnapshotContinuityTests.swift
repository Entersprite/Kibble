import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

struct CallSnapshotContinuityTests {
    @Test func skippedTerminalStateRetiresPreviousCallBeforeDeliveringTheNextIncomingCall() throws {
        var projection = ServiceCallStateProjection()
        let source = UUID().uuidString
        let old = call(phase: .connected)
        let next = call(phase: .incoming)
        _ = try projection.accept(.init(version: source + ":1", isListening: true, call: old))
        let events = try projection.accept(.init(version: source + ":4", isListening: true, call: next))
        let snapshots = events.compactMap {
            if case let .snapshot(call) = $0 {
                return call
            }; return nil
        }
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.id == old.id)
        #expect(snapshots.first?.phase.isTerminal == true)
        #expect(snapshots.last == next)
        #expect(try projection.accept(.init(version: source + ":2", call: old)).isEmpty)
    }

    @Test func missingCallInACompleteSnapshotRetiresPreviousPresentation() throws {
        var projection = ServiceCallStateProjection()
        let source = UUID().uuidString
        let old = call(phase: .incoming)
        _ = try projection.accept(.init(version: source + ":1", isListening: true, call: old))
        let events = try projection.accept(.init(version: source + ":2", isListening: true))
        let snapshots = events.compactMap {
            if case let .snapshot(call) = $0 {
                return call
            }; return nil
        }
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.id == old.id)
        #expect(snapshots.first?.phase.isTerminal == true)
    }

    private func call(phase: AudioCallPhase) -> AudioCallSnapshot {
        .init(id: UUID(), recipient: .init(
            conversationID: .init("conversation"), memberID: .init("peer"), displayName: "Peer"
        ), direction: .incoming, phase: phase)
    }
}
