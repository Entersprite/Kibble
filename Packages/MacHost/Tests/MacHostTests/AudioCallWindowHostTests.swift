import AppKit
import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
struct AudioCallWindowHostTests {
    private func call(phase: AudioCallPhase = .incoming) -> AudioCallSnapshot {
        AudioCallSnapshot(
            id: UUID(),
            recipient: AudioCallRecipient(
                conversationID: Conversation.ID("dm-test"), memberID: Member.ID("peer"),
                displayName: "Maya"
            ),
            direction: .incoming,
            phase: phase
        )
    }

    private let actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})

    @Test func pausedOrSilentIncomingDoesNotRaiseAWindowButExplicitOpenStillWorks() {
        var presented = 0
        var attention = 0
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in }, present: { _ in presented += 1 },
            incomingAttention: { attention += 1 }
        )
        let incoming = call()
        host.update(call: incoming, windowRequests: 1, alertsIncoming: false)
        #expect(presented == 0)
        #expect(attention == 0)
        host.update(call: incoming, windowRequests: 2, alertsIncoming: false)
        #expect(presented == 1)
        #expect(attention == 0)
        host.update(call: nil, windowRequests: 2)
    }

    @Test func incomingAndExplicitRequestsRaiseTheSameWindow() throws {
        var presented: [NSWindow] = []
        var attentionRequests = 0
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in }, present: { presented.append($0) },
            incomingAttention: { attentionRequests += 1 }
        )
        var incoming = call()
        host.update(call: incoming, windowRequests: 1)
        let window = try #require(presented.first)
        incoming.phase = .connecting
        host.update(call: incoming, windowRequests: 1)
        incoming.phase = .connected
        host.update(call: incoming, windowRequests: 1)
        #expect(presented.count == 1)
        #expect(attentionRequests == 1)
        host.update(call: incoming, windowRequests: 2)
        #expect(presented.count == 2)
        #expect(attentionRequests == 1)
        #expect(presented.last === window)
        host.update(call: call(), windowRequests: 3)
        #expect(presented.count == 3)
        #expect(attentionRequests == 2)
        #expect(host.window === window)
        host.update(call: nil, windowRequests: 3)
    }

    @Test func manualCloseCallsLifecycleAndEndDoesNotReopenIt() throws {
        var closeCount = 0
        var presents = 0
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in closeCount += 1 }, present: { _ in presents += 1 }
        )
        var incoming = call()
        host.update(call: incoming, windowRequests: 1)
        let window = try #require(host.window)
        window.close()
        #expect(closeCount == 1)
        incoming.phase = .ended
        host.update(call: incoming, windowRequests: 1)
        #expect(presents == 1)
        #expect(host.window === window)
        host.update(call: nil, windowRequests: 1)
        #expect(closeCount == 1)
    }

    @Test func sessionStopClosesWithoutSendingAnotherCallAction() throws {
        var closeCount = 0
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in closeCount += 1 }, present: { _ in }
        )
        host.update(call: call(phase: .connected), windowRequests: 1)
        #expect(host.window != nil)
        host.update(call: nil, windowRequests: 1)
        #expect(closeCount == 0)
        host.update(call: call(), windowRequests: 1)
        let window = try #require(host.window)
        // The presentation hook intentionally never orders the closed window
        // front. Deliver the delegate event a reopened window would receive.
        host.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(closeCount == 1)
    }

    @Test func controlsAndCloseRemainBoundToThePresentedCall() throws {
        var actionIDs: [UUID] = []
        var closedIDs: [UUID] = []
        let host = AudioCallWindowHost(
            actions: { id in
                actionIDs.append(id)
                return actions
            },
            windowClosed: { closedIDs.append($0) },
            present: { _ in }
        )
        let first = call(phase: .ended)
        let next = call()
        host.update(call: first, windowRequests: 1)
        let window = try #require(host.window)
        // The controller may already hold `next` while the observer has yet
        // to present it. Closing the old window must still identify `first`.
        let closed = Notification(name: NSWindow.willCloseNotification, object: window)
        host.windowWillClose(closed)
        #expect(closedIDs == [first.id])
        host.update(call: next, windowRequests: 2)
        host.windowWillClose(closed)
        #expect(closedIDs == [first.id, next.id])
        #expect(actionIDs == [first.id, next.id])
        host.update(call: nil, windowRequests: 2)
    }
}
