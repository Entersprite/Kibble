import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func reconcileHands(_ snapshot: MeetCallCollectionsWire.Snapshot) async {
        guard !closed else { return }
        guard let hands = snapshot.hands else {
            observedOwnHand = nil
            await clearAutomaticHandLowering()
            return
        }
        guard hands.version >= (handVersion ?? 0) else { return }
        let local = participantLocalDevice
        let newer = handVersion.map { hands.version > $0 } ?? false
        applyHands(hands)
        guard state == .active, !isSuspended, disconnectedAt == nil, let local,
              let roster = snapshot.devices, roster.version >= max(
                  deviceVersion ?? 0,
                  participantVersion ?? 0
              ),
              roster.values.contains(where: {
                  $0.name == local && !$0.isDeleted && !$0.isPresentation && $0.joinState == 1
              }) else {
            observedOwnHand = nil
            await clearAutomaticHandLowering()
            return
        }
        let current = participantHands?[local]?.name
        let previous = observedOwnHand
        observedOwnHand = current
        if automaticHand.name != current {
            await clearAutomaticHandLowering()
        }
        guard newer, !closed, state == .active, observedOwnHand == current else { return }
        let localRequest = requestedOwnLowering
        if current != localRequest {
            requestedOwnLowering = nil
        }
        if let previous, current == nil, previous != localRequest {
            activities.ownHandLowered = UUID()
            await receiveActivities?(activities)
        }
    }

    func applyHands(_ hands: MeetCallCollectionsWire.Hands) {
        guard handVersion.map({ hands.version > $0 }) ?? true else { return }
        handVersion = hands.version
        participantHands = Dictionary(uniqueKeysWithValues: hands.values.map { ($0.device, $0) })
        ownHandRaised = nil
    }

    func moderateHands(_ activity: CallActivity) async throws {
        let bulk = activity.action == "lowerAllHands"
        guard activity.enabled, activity.participantIDs.isEmpty, bulk == (activity.resourceID == nil),
              let local = participantLocalDevice else {
            throw ChatError.unsupported(capability: "callHandModeration")
        }
        let before = try await device.collections()
        try await check()
        if let activityState = before.activities {
            await reconcileActivities(activityState)
            try await check()
        }
        guard state == .active, !isSuspended, disconnectedAt == nil,
              let roster = before.devices, roster.version >= (participantVersion ?? 0),
              let access = before.activities?.hostAccess, access.canManage,
              access.version == hostControls.access?.version, access.role == hostControls.access?.role,
              let hands = before.hands, hands.version >= (handVersion ?? 0) else {
            throw ChatError.unsupported(capability: "callHandModeration")
        }
        let targets = try moderatedHandNames(activity, local: local, roster: roster, hands: hands)
        applyHands(hands)
        guard let first = targets.first else {
            await publishParticipants()
            return
        }
        if bulk {
            requestedOwnLowering = hands.values.first { $0.device == local }?.name
            observedOwnHand = nil
            await clearAutomaticHandLowering()
            try await check()
            try await device.clearHands()
        } else {
            try await device.lowerHand(first)
        }
        try await check()
        needsRefresh = true
        let after = try await device.collections()
        try await check()
        guard let confirmed = after.hands, confirmed.version > hands.version,
              confirmed.version >= (handVersion ?? 0) else {
            throw ChatError.transport("Raised hands could not be refreshed.")
        }
        applyHands(confirmed)
        await publishParticipants()
        guard targets.isDisjoint(with: confirmed.values.map(\.name)) else {
            throw ChatError.transport("Some raised hands could not be lowered.")
        }
    }

    private func moderatedHandNames(
        _ activity: CallActivity,
        local: String,
        roster: MeetCallCollectionsWire.Devices,
        hands: MeetCallCollectionsWire.Hands
    ) throws -> Set<String> {
        guard let handle = activity.resourceID else { return Set(hands.values.map(\.name)) }
        guard let target = roster.values.first(where: {
            $0.name != local && $0.primaryDevice != local && !$0.isPresentation
                && !$0.isDeleted && $0.joinState == 1 && participantHandles[$0.name] == handle
        }) else {
            throw ChatError.unsupported(capability: "callHandModeration")
        }
        return Set(hands.values.filter { $0.device == target.name }.map(\.name))
    }
}
