import ChatKit
import GChatBridgeCore

extension NativeMeetCallSession {
    static let sharedPinLimit = 3

    func reconcileSharedPinGrant(_ grant: MeetActivityCollections.HostAccess?) {
        guard let grant, hostControls.sharedPinGrant.map({
            grant.version > $0.version || (grant.version == $0.version && !grant.canPinForEveryone)
        }) ?? true else { return }
        hostControls.sharedPinGrant = (grant.version, grant.canPinForEveryone)
    }

    func setPinForEveryone(_ activity: CallActivity) async throws {
        let (local, roster) = try await verifyParticipantAction(activity.action)
        let joined = roster.values.filter { $0.joinState == 1 && !$0.isDeleted }
        guard activity.participantIDs.isEmpty, let id = activity.resourceID,
              let target = joined.first(where: { participantHandles[$0.name] == id }),
              let pinned = target.isPinnedForEveryone else {
            throw ChatError.unsupported(capability: "sharedParticipantPin")
        }
        if pinned == activity.enabled {
            return
        }
        guard !activity.enabled || (joined.allSatisfy { $0.isPinnedForEveryone != nil }
            && joined.filter { $0.isPinnedForEveryone == true }.count < Self.sharedPinLimit) else {
            throw ChatError.unsupported(capability: "sharedParticipantPin")
        }
        defer { needsRefresh = true }
        try await device.setPinForEveryone(target.name, pinned: activity.enabled)
        try await check()
        let confirmed = try await device.collections()
        try await check()
        guard let current = confirmed.devices, current.version > roster.version,
              current.values.contains(where: { $0.name == local && $0.joinState == 1 && !$0.isDeleted }),
              current.values.contains(where: {
                  $0.name == target.name && $0.joinState == 1 && !$0.isDeleted
                      && $0.isPinnedForEveryone == activity.enabled
              }) else { throw ChatError.transport("The shared pin could not be confirmed.") }
        if let activities = confirmed.activities {
            await reconcileActivities(activities)
        }
        try await check()
        await reconcileParticipants(current, local: local)
    }
}
