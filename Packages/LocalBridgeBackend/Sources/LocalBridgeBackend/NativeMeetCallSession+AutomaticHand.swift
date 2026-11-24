import ChatKit
import Foundation

extension NativeMeetCallSession {
    var connectedOwnHand: String? {
        guard ready, !closed, closing == nil, state == .active,
              !isSuspended, disconnectedAt == nil, let local = participantLocalDevice,
              let hand = observedOwnHand, participantHands?[local]?.name == hand else { return nil }
        return hand
    }

    func updateAutomaticHandLowering() async {
        guard let hand = connectedOwnHand, hand != automaticHand.suppressedName else {
            await clearAutomaticHandLowering()
            return
        }
        guard connection == nil, !handOperation else { return }
        automaticHand.track(hand)
        if let deadline = automaticHand.deadline {
            guard now() >= deadline else { return }
            automaticHand.suppressedName = hand
            await clearAutomaticHandLowering()
            do {
                try await setHandRaised(false, expectedName: hand)
            } catch {
                needsRefresh = true
            }
            return
        }
        let sample = await media.localAudioActivity()
        guard connectedOwnHand == hand, automaticHand.name == hand,
              automaticHand.suppressedName != hand, connection == nil,
              automaticHand.observe(sample, at: now()) else { return }
        automaticHand.deadline = now().advanced(by: .seconds(10))
        activities.automaticHandLowering = CallAutomaticHandLowering(
            id: UUID(), deadline: Date().addingTimeInterval(10)
        )
        updateActivityAvailability()
        await receiveActivities?(activities)
    }

    func keepAutomaticHandRaised(_ activity: CallActivity) async throws {
        try await check()
        guard activity.enabled, activity.participantIDs.isEmpty,
              let prompt = activities.automaticHandLowering, let hand = automaticHand.name,
              activity.resourceID == prompt.id, connectedOwnHand == hand else {
            throw ChatError.unsupported(capability: "keepHandRaised")
        }
        automaticHand.suppressedName = hand
        await clearAutomaticHandLowering()
    }

    func clearAutomaticHandLowering() async {
        automaticHand.clearObservation()
        guard activities.automaticHandLowering != nil else { return }
        activities.automaticHandLowering = nil
        updateActivityAvailability()
        await receiveActivities?(activities)
    }
}

struct NativeAutomaticHandLowering {
    private(set) var name: String?
    var suppressedName: String?
    var deadline: ContinuousClock.Instant?
    private var timestamp: Double?
    private var began: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?

    mutating func track(_ name: String) {
        guard self.name != name else { return }
        clearObservation()
        self.name = name
    }

    mutating func clearObservation() {
        name = nil
        deadline = nil
        timestamp = nil
        began = nil
        last = nil
    }

    mutating func observe(_ sample: CallLocalAudioActivity?, at now: ContinuousClock.Instant) -> Bool {
        guard let sample, sample.timestamp.isFinite,
              timestamp.map({ sample.timestamp > $0 }) ?? true,
              (0 ... 1).contains(sample.level) else {
            began = nil
            return false
        }
        timestamp = sample.timestamp
        defer { last = now }
        guard sample.level >= 0.02 else {
            began = nil
            return false
        }
        if let last, now - last > .milliseconds(1750) {
            began = nil
        }
        let start = began ?? now
        began = start
        return now - start >= .seconds(3)
    }
}
