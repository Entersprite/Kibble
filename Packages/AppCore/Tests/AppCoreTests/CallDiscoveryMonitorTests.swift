import ChatKit
import Foundation
import Observation
import Testing
@testable import AppCore

/// Discovery for the conversation on screen: bounded, fresh, and never a
/// stale or foreign answer presented as a call going on.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallDiscoveryMonitorTests {
    private let space = Conversation.ID("opaque-space")
    private let other = Conversation.ID("opaque-other")

    @Observable @MainActor
    final class Scene {
        var watch = CallDiscoveryMonitor.Watch()
    }

    @MainActor
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// The provider's own clock, deliberately far from the client's.
    private func active(_ id: Conversation.ID, people: Int? = 3) -> ConversationCallAvailability {
        ConversationCallAvailability(
            conversationID: id, status: .active, checkedAt: Date(timeIntervalSince1970: 0),
            totalParticipants: people
        )
    }

    @Test func aReceivedActiveAnswerOffersJoinUntilItIsTooOld() async {
        let clock = Clock()
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .seconds(60), maximumAge: 45) { clock.now }
        var asked: [Conversation.ID] = []
        monitor.start(watching: { scene.watch }, fetch: { id in
            asked.append(id)
            return active(id)
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { monitor.isActive(in: space) })
        #expect(monitor.participantCount(in: space) == 3)
        #expect(asked == [space])
        #expect(!monitor.isActive(in: other))
        clock.now += 44
        #expect(monitor.isActive(in: space))
        clock.now += 2
        #expect(!monitor.isActive(in: space))
        monitor.stop()
    }

    @Test func movingToAnotherConversationDropsTheFirstAnswerAtOnce() async {
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .seconds(60))
        var hold: CheckedContinuation<Void, Never>?
        monitor.start(watching: { scene.watch }, fetch: { id in
            if id == other {
                await withCheckedContinuation { hold = $0 }
            }
            return active(id)
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { monitor.isActive(in: space) })
        scene.watch = .init(conversation: other)
        #expect(await eventually { hold != nil })
        #expect(monitor.availability == nil)
        #expect(!monitor.isActive(in: space))
        hold?.resume()
        #expect(await eventually { monitor.isActive(in: other) })
        monitor.stop()
    }

    @Test func anAnswerAboutAnotherConversationIsNeverShown() async {
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .seconds(60))
        var answered = false
        monitor.start(watching: { scene.watch }, fetch: { _ in
            answered = true
            return active(other)
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { answered })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(monitor.availability == nil)
        #expect(!monitor.isActive(in: space))
        #expect(!monitor.isActive(in: other))
        monitor.stop()
    }

    @Test func aFailureOrAnUnknownStatusIsNotACallGoingOn() async {
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .milliseconds(10))
        var answers: [ConversationCallAvailability?] = [
            active(Conversation.ID("opaque-space")),
            nil,
            ConversationCallAvailability(
                conversationID: Conversation.ID("opaque-space"), status: .unknown("future"), checkedAt: .now
            )
        ]
        var calls = 0
        monitor.start(watching: { scene.watch }, fetch: { _ in
            calls += 1
            guard !answers.isEmpty else { return nil }
            guard let next = answers.removeFirst() else { throw ChatError.transport("private") }
            return next
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { monitor.isActive(in: space) })
        #expect(await eventually { calls >= 2 && monitor.availability == nil })
        #expect(await eventually { calls >= 3 })
        #expect(!monitor.isActive(in: space))
        monitor.stop()
    }

    @Test func aRepeatedWatchAsksOnceAndAChangeOfCallAsksAgain() async {
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .seconds(60))
        var asked = 0
        monitor.start(watching: { scene.watch }, fetch: { id in
            asked += 1
            return active(id)
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { asked == 1 })
        scene.watch = .init(conversation: space)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(asked == 1)
        scene.watch = .init(conversation: space, inCall: true)
        #expect(await eventually { asked == 2 })
        scene.watch = .init(conversation: space, inCall: true, latestCallMessage: Message.ID("call-entry"))
        #expect(await eventually { asked == 3 })
        monitor.stop()
    }

    @Test func nothingOnScreenAndStoppingAskNothingFurther() async {
        let scene = Scene()
        let monitor = CallDiscoveryMonitor(interval: .milliseconds(10))
        var asked = 0
        monitor.start(watching: { scene.watch }, fetch: { id in
            asked += 1
            return active(id)
        })
        scene.watch = .init(conversation: space)
        #expect(await eventually { monitor.isActive(in: space) })
        scene.watch = .init()
        #expect(await eventually { monitor.availability == nil })
        let settled = asked
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked == settled)
        scene.watch = .init(conversation: space)
        #expect(await eventually { monitor.isActive(in: space) })
        monitor.stop()
        #expect(monitor.availability == nil)
        let stopped = asked
        try? await Task.sleep(for: .milliseconds(40))
        #expect(asked == stopped)
    }
}
