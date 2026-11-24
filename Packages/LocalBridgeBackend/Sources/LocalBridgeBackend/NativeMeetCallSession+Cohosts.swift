import ChatKit
import GChatBridgeCore

extension NativeMeetCallSession {
    func changeParticipantCohost(_ activity: CallActivity) async throws {
        guard let id = activity.resourceID,
              let name = participantHandles.first(where: { $0.value == id })?.key else {
            throw ChatError.unsupported(capability: "callParticipantRole")
        }
        let (local, devices) = try await verifyParticipantAction(activity.action)
        let from: MeetDeviceWire.Role = activity.enabled ? .participant : .cohost
        let to: MeetDeviceWire.Role = activity.enabled ? .cohost : .participant
        guard name != local, joinedRole(name, in: devices) == from else {
            throw ChatError.unsupported(capability: "callParticipantRole")
        }
        try await device.changeParticipantRole(name, cohost: activity.enabled)
        try await check()
        let after = try await device.joinedActivityCollections(including: .space)
        try await check()
        await reconcileActivities(after)
        try await check()
        guard let confirmed = after.devices, confirmed.version > devices.version,
              confirmed.version > (participantVersion ?? 0), joinedRole(local, in: confirmed) != nil else {
            throw ChatError.transport("The participant’s role change could not be confirmed.")
        }
        await reconcileParticipants(confirmed, local: local)
        try await check()
        guard joinedRole(name, in: confirmed) == to else {
            throw ChatError.transport("The participant’s role change could not be confirmed.")
        }
    }

    private func joinedRole(_ name: String, in devices: MeetCallCollectionsWire.Devices) -> MeetDeviceWire
        .Role? {
        devices.values.first {
            $0.name == name && $0.joinState == 1 && !$0.isDeleted && !$0.isPresentation
        }?.role
    }
}
