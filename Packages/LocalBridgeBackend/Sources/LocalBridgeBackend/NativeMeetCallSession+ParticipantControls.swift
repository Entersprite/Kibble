import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func verifyParticipantAction(_ action: String) async throws -> (
        local: String,
        roster: MeetCallCollectionsWire.Devices
    ) {
        guard let local = participantLocalDevice else { throw MeetDeviceSessionError.notJoined }
        let before = try await device.joinedActivityCollections(including: .space)
        try await check()
        await reconcileActivities(before)
        try await check()
        guard state == .active, !isSuspended, disconnectedAt == nil,
              let devices = before.devices, devices.version >= (participantVersion ?? 0),
              hasFreshParticipantGrant(action, in: before),
              activities.availableActions.contains(action) else {
            throw ChatError.unsupported(capability: "callParticipantControls")
        }
        return (local, devices)
    }

    private func hasFreshParticipantGrant(
        _ action: String,
        in snapshot: MeetActivityCollections.Snapshot
    ) -> Bool {
        guard let access = snapshot.hostAccess else { return false }
        if action == "setPinForEveryone" {
            return access.canPinForEveryone && access.version == hostControls.sharedPinGrant?.version
                && hostControls.sharedPinGrant?.enabled == true
        }
        if ["removeParticipant", "blockParticipant", "sendParticipantToWaitingRoom"].contains(action) {
            let freshRemoval = access.canRemoveParticipants
                && access.version == hostControls.removalGrant?.version
                && hostControls.removalGrant?.enabled == true
            return freshRemoval && (action != "sendParticipantToWaitingRoom"
                || (access.role == .host && hostControls.access?.role == .host
                    && access.version == hostControls.access?.version && hasFreshWaitingRoom(snapshot)))
        }
        if ["respondToAdmission", "respondToAdmissions"].contains(action) {
            return hasFreshAdmissionAccess(action, in: snapshot, access: access)
        }
        guard access.canManage, access.role == hostControls.access?.role,
              access.version == hostControls.access?.version,
              let revision = snapshot.versions[1], revision == activityVersions[1],
              let settings = snapshot.space.flatMap(MeetActivityWire.hostSettings) else { return false }
        return settings.managementEnabled == activities.hostSettings?.managementEnabled
    }

    private func hasFreshWaitingRoom(_ snapshot: MeetActivityCollections.Snapshot) -> Bool {
        guard hostControls.waitingRoomEnabled != false else { return false }
        if let version = snapshot.versions[1], version != activityVersions[1] {
            return false
        }
        if let enabled = snapshot.space.flatMap(MeetActivityWire.waitingRoomEnabled) {
            return enabled && hostControls.waitingRoomEnabled == true
        }
        return snapshot.devices?.values.contains(where: Self.isInWaitingRoom) == true
    }

    func ejectParticipant(_ activity: CallActivity) async throws {
        guard activity.enabled, let id = activity.resourceID else {
            throw ChatError.unsupported(capability: "callParticipantControls")
        }
        let (local, roster) = try await verifyParticipantAction(activity.action)
        guard let target = roster.values.first(where: { device in
            device.name != local && device.joinState == 1 && !device.isDeleted && !device.isPresentation
                && participantHandles[device.name] == id
        }) else { throw ChatError.unsupported(capability: "callParticipantControls") }
        defer { needsRefresh = true }
        switch activity.action {
        case "sendParticipantToWaitingRoom":
            guard activity.participantIDs.isEmpty, Self.isWaitingRoomTarget(target) else {
                throw ChatError.unsupported(capability: "waitingRoom")
            }
            if try await !device.sendParticipantToWaitingRoom(target.name) {
                try await confirmWaitingRoomMove(of: target, after: roster)
            }
        case "blockParticipant":
            let own = roster.values.first { $0.name == local }
            guard activity.participantIDs.isEmpty, !Self.sameMeetingUser(target, own) else {
                throw ChatError.unsupported(capability: "callParticipantControls")
            }
            if try await !device.blockParticipant(target.name) {
                try await confirmBlock(of: target.name, local: local, after: roster.version)
            }
        default:
            try await device.removeParticipant(target.name)
        }
        try await check()
    }

    private func confirmWaitingRoomMove(
        of target: MeetDeviceWire.Device, after before: MeetCallCollectionsWire.Devices
    ) async throws {
        let otherIDs = before.values.lazy.filter {
            $0.name != target.name && Self.isCurrentParticipantDevice($0)
        }.flatMap(\.conferenceUserIDs)
        let targetIDs = target.conferenceUserIDs.subtracting(otherIDs)
        let existing = Set(before.values.map(\.name))
        let deadline = ContinuousClock.now + .seconds(5)
        var observedVersion = before.version
        while ContinuousClock.now < deadline {
            try await check()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            let snapshot = try await device.joinedActivityCollections(
                including: .space, timeout: remaining
            )
            try await check()
            guard state == .active, !isSuspended, disconnectedAt == nil else { break }
            let currentVersion = max(
                deviceVersion ?? 0,
                participantVersion ?? 0,
                hostControls.access?.version ?? 0
            )
            if let roster = snapshot.devices, roster.version > observedVersion,
               roster.version >= currentVersion {
                observedVersion = roster.version
                guard snapshot.hostAccess?.role == .host else { break }
                if Self.observedWaitingRoomMove(
                    target.name,
                    targetIDs: targetIDs,
                    existing: existing,
                    in: roster
                ) {
                    return
                }
            }
            let pause = min(.milliseconds(400), ContinuousClock.now.duration(to: deadline))
            if pause > .zero {
                try await Task.sleep(for: pause)
            }
        }
        throw ChatError.transport("The move to the waiting room could not be confirmed.")
    }

    private static func observedWaitingRoomMove(
        _ target: String, targetIDs: Set<String>, existing: Set<String>,
        in roster: MeetCallCollectionsWire.Devices
    ) -> Bool {
        guard let ejected = roster.values.first(where: { $0.name == target }) else { return false }
        if ejected.wasSentToWaitingRoom {
            return true
        }
        guard ejected.wasRemoved, ejected.isDeleted else { return false }
        let matches = roster.values.filter {
            isCurrentParticipantDevice($0) && !targetIDs.isDisjoint(with: $0.conferenceUserIDs)
        }
        guard matches.count == 1, let waiting = matches.first else { return false }
        return isInWaitingRoom(waiting) && !existing.contains(waiting.name)
    }

    private static func isCurrentParticipantDevice(_ device: MeetDeviceWire.Device) -> Bool {
        !device.isDeleted && !device.isPresentation && [1, 3, 9, 13].contains(device.joinState)
    }

    private func confirmBlock(of target: String, local: String, after version: UInt64) async throws {
        try await check()
        let snapshot = try await device.collections()
        try await check()
        guard let roster = snapshot.devices, roster.version > version,
              roster.values.contains(where: { $0.name == local && $0.joinState == 1 && !$0.isDeleted }) else {
            throw ChatError.transport("The block could not be confirmed.")
        }
        if let row = roster.values.first(where: { $0.name == target }),
           !row.isDeleted, ![4, 6, 7, 8, 11].contains(row.joinState) {
            throw ChatError.transport("The block could not be confirmed.")
        }
    }

    static func sameMeetingUser(_ first: MeetDeviceWire.Device, _ second: MeetDeviceWire.Device?) -> Bool {
        guard let userID = first.meetingUserID else { return false }
        return userID == second?.meetingUserID
    }

    static func isWaitingRoomTarget(_ device: MeetDeviceWire.Device) -> Bool {
        device.role == .participant && device.supportsWaitingRoom
    }

    static func isInWaitingRoom(_ device: MeetDeviceWire.Device) -> Bool {
        device.joinState == 13 && !device.isDeleted && !device.isPresentation
    }
}
