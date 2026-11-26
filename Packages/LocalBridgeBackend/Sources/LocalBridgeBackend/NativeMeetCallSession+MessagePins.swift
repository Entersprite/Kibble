import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    private struct MeetingMessagePinState {
        let version: UInt64
        let isPinned: Bool
        let ownedByLocal: Bool
    }

    static func canChangeMeetingMessagePin(
        sender: String?, local: String?, pinned: Bool, role: MeetDeviceWire.Role?
    ) -> Bool {
        guard let local else { return false }
        return local == sender || (pinned && role == .host)
    }

    func setMeetingMessagePin(_ activity: CallActivity, sequence: UInt64) async throws {
        let name = try activityResource(activity.resourceID, kind: "message")
        let current = try await checkMeetingMessagePin(activity, name: name)
        if current.isPinned == activity.enabled {
            return
        }
        defer { needsRefresh = true }
        let frame = try MeetActivityDataWire.updateChatPin(
            name: name, pinned: activity.enabled, sequence: sequence
        )
        let response = try await media.exchangeActivityData(channel: "meet_messages", data: frame) {
            MeetActivityDataWire.isChatResponse($0, sequence: sequence)
        }
        try await check()
        let revision = try MeetActivityDataWire.chatPinRevision(
            response, sequence: sequence, name: name, pinned: activity.enabled
        )
        if let revision, revision > current.version, revision - current.version == 1,
           let index = activities.messages.firstIndex(where: { $0.id == activity.resourceID }) {
            activityVersions[3] = revision
            activities.messages[index].isPinned = activity.enabled
            activities.messages[index].canChangePin = current.ownedByLocal ? true : nil
            await receiveActivities?(activities)
        } else {
            try await confirmMeetingMessagePin(
                activity,
                name: name,
                after: current.version,
                receipt: revision
            )
        }
    }

    private func checkMeetingMessagePin(
        _ activity: CallActivity, name: String
    ) async throws -> MeetingMessagePinState {
        let current = try await device.activityCollections(refreshHostAccess: true)
        let local = await device.localDeviceName
        try await check()
        await reconcileActivities(current)
        try await check()
        guard !isSuspended, disconnectedAt == nil, activity.participantIDs.isEmpty,
              activities.availableActions.contains(activity.action),
              let local, let roster = current.devices, roster.version >= (participantVersion ?? 0),
              let own = roster.values.first(where: {
                  $0.name == local && $0.joinState == 1 && !$0.isDeleted && !$0.isPresentation
              }),
              let baseline = current.versions[3], baseline == activityVersions[3],
              let message = Self.meetingMessage(name, from: current),
              let pinned = MeetActivityDataWire.publicChatPin(in: message)
        else { throw ChatError.unsupported(capability: "meetingMessagePin") }
        let sender = MeetActivityCollections.text(2, message)
        let role = roster.version == hostControls.access?.version && own.role == hostControls.access?.role
            ? own.role : nil
        guard Self.canChangeMeetingMessagePin(sender: sender, local: local, pinned: pinned, role: role),
              !activity.enabled || sender == local
        else { throw ChatError.unsupported(capability: "meetingMessagePin") }
        return MeetingMessagePinState(version: baseline, isPinned: pinned, ownedByLocal: sender == local)
    }

    private func confirmMeetingMessagePin(
        _ activity: CallActivity, name: String, after baseline: UInt64, receipt: UInt64?
    ) async throws {
        let current = try await device.activityCollections()
        try await check()
        guard let version = current.versions[3], version > baseline, version >= (receipt ?? 0),
              let message = Self.meetingMessage(name, from: current),
              MeetActivityDataWire.publicChatPin(in: message) == activity.enabled else {
            throw ChatError.transport("The message pin could not be confirmed.")
        }
        await reconcileActivities(current)
    }

    private static func meetingMessage(
        _ name: String,
        from snapshot: MeetActivityCollections.Snapshot
    ) -> Data? {
        snapshot.messages?.first { MeetActivityCollections.text(1, $0) == name }
    }
}
