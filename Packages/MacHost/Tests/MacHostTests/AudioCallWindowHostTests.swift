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

    @Test func windowIsADarkStageThatKeepsItsContentAcrossUpdates() throws {
        let host = AudioCallWindowHost(actions: { _ in actions }, windowClosed: { _ in }, present: { _ in })
        var outgoing = call(phase: .connecting)
        host.update(call: outgoing, windowRequests: 1)
        let window = try #require(host.window)
        let content = try #require(window.contentView)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.title == "Maya")
        // Replacing the hosting view would reset the view's own state and
        // restart its renderers on every snapshot.
        outgoing.phase = .connected
        host.update(call: outgoing, windowRequests: 1)
        host.update(call: call(), windowRequests: 2)
        #expect(window.contentView === content)
        #expect(window.frame.width == CallLayout.compact.width)
        #expect(window.frame.height >= CallLayout.compact.height)
        host.update(call: nil, windowRequests: 2)
    }

    @Test func timingStartsAtTheFirstConnectionAndStopsAtTheEnd() {
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in }, present: { _ in }, now: { clock }
        )
        var outgoing = call(phase: .ringing)
        host.update(call: outgoing, windowRequests: 1)
        #expect(host.timing == CallTiming())
        clock += 5
        outgoing.phase = .connected
        host.update(call: outgoing, windowRequests: 1)
        clock += 60
        outgoing.isMuted = true
        host.update(call: outgoing, windowRequests: 1)
        #expect(host.timing.connectedAt == Date(timeIntervalSinceReferenceDate: 1005))
        #expect(host.timing.endedAt == nil)
        clock += 7
        outgoing.phase = .ended
        host.update(call: outgoing, windowRequests: 1)
        clock += 30
        host.update(call: outgoing, windowRequests: 2)
        #expect(host.timing.endedAt == Date(timeIntervalSinceReferenceDate: 1072))
        // The next call starts its own clock; an unanswered one never had one.
        var next = call()
        host.update(call: next, windowRequests: 3)
        #expect(host.timing == CallTiming())
        next.phase = .declined
        host.update(call: next, windowRequests: 3)
        #expect(host.timing == CallTiming())
        host.update(call: nil, windowRequests: 3)
    }

    @Test func videoLayoutStaysForTheCallThatShowedItAndResetsForTheNext() {
        let first = call(phase: .connected)
        var layout = CallWindowLayout().next(call: first, hasVideo: false)
        #expect(!layout.isVideo)
        layout = layout.next(call: first, hasVideo: true)
        #expect(layout.isVideo)
        layout = layout.next(call: first, hasVideo: false)
        #expect(layout.isVideo)
        var ended = first
        ended.phase = .ended
        #expect(layout.next(call: ended, hasVideo: false).isVideo)
        #expect(!layout.next(call: call(), hasVideo: false).isVideo)
        // A finished call never switches to video late.
        #expect(!CallWindowLayout().next(call: ended, hasVideo: true).isVideo)
    }

    @Test func aResizedWindowKeepsItsCenterAndStaysOnScreen() {
        let frame = NSRect(x: 100, y: 100, width: 360, height: 492)
        let grown = AudioCallWindowHost.frame(of: CallLayout.video, around: frame, on: nil)
        #expect(grown.midX == frame.midX)
        #expect(grown.midY == frame.midY)
        #expect(grown.size == CallLayout.video)
        guard let screen = NSScreen.main else { return }
        let corner = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 360, height: 492)
        let kept = AudioCallWindowHost.frame(of: CallLayout.video, around: corner, on: screen)
        #expect(screen.visibleFrame.contains(kept))
    }
}
