import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    enum AdmissionAccess {
        case organizer, cohost

        var actions: [String] {
            self == .organizer ? ["respondToAdmission", "respondToAdmissions"] : ["respondToAdmission"]
        }

        func canAdmit(_ state: UInt64) -> Bool {
            state == 3 || (self == .organizer && state == 13)
        }
    }

    var admissionAccess: AdmissionAccess? {
        switch hostControls.access?.role {
        case .host: .organizer
        case .cohost
            where !unavailableActivityFields.contains(1) && hostControls.settings?.managementEnabled == true:
            .cohost
        default: nil
        }
    }

    func hasFreshAdmissionAccess(
        _ action: String, in snapshot: MeetActivityCollections.Snapshot,
        access: MeetActivityCollections.HostAccess
    ) -> Bool {
        guard access.role == hostControls.access?.role, access.version == hostControls.access?.version,
              let scope = admissionAccess, scope.actions.contains(action) else { return false }
        if scope == .organizer {
            return true
        }
        guard let revision = snapshot.versions[1], revision == activityVersions[1],
              let settings = snapshot.space.flatMap(MeetActivityWire.hostSettings) else { return false }
        return settings.managementEnabled
    }

    func reconcileWaitingParticipants(_ roster: MeetCallCollectionsWire.Devices?) {
        let scope = admissionAccess
        if hostControls.waitingAccess != scope {
            hostControls.waitingParticipants.removeAll()
            hostControls.waitingAccess = scope
        }
        if let scope, let roster, roster.version == hostControls.access?.version,
           roster.version >= (participantVersion ?? 0) {
            rememberWaitingParticipants(roster, scope: scope)
        }
        activities.waitingParticipants = hostControls.waitingParticipants.keys.sorted()
            .compactMap { hostControls.waitingParticipants[$0] }
    }

    private func rememberWaitingParticipants(
        _ roster: MeetCallCollectionsWire.Devices,
        scope: AdmissionAccess
    ) {
        let waiting = roster.values.filter { device in
            !device.isDeleted && !device.isPresentation && scope.canAdmit(device.joinState)
        }
        guard waiting.count <= 256 else {
            hostControls.waitingParticipants.removeAll()
            return
        }
        let previous = hostControls.waitingParticipants
        hostControls.waitingParticipants = Dictionary(uniqueKeysWithValues: waiting.map { device in
            let warning = waitingWarning(device)
            let retainedID = previous[device.name].flatMap { prior -> UUID? in
                guard prior.isInWaitingRoom == (device.joinState == 13),
                      warning == nil || warning == prior.warning else { return nil }
                return prior.id
            }
            return (device.name, CallWaitingParticipant(
                id: retainedID ?? UUID(),
                name: device.displayName ?? "Guest", canDeny: scope == .organizer && device.joinState == 3,
                warning: warning, isJoinRequest: scope == .cohost ? true : nil
            ))
        })
    }

    func respondToWaitingParticipants(_ activity: CallActivity) async throws {
        let bulk = activity.action == "respondToAdmissions"
        let ids = bulk ? activity.participantIDs : activity.resourceID.map { [$0] } ?? []
        guard bulk ? activity.resourceID == nil : activity.participantIDs.isEmpty,
              !ids.isEmpty, ids.count <= 256, Set(ids).count == ids.count else {
            throw ChatError.unsupported(capability: "callAdmission")
        }
        let (local, roster) = try await verifyParticipantAction(activity.action)
        guard let scope = admissionAccess, activity.enabled || scope == .organizer else {
            throw ChatError.unsupported(capability: "callAdmission")
        }
        let requested = Set(ids)
        let targets = roster.values.filter {
            $0.name != local && isEligibleAdmissionTarget(
                $0,
                requested: requested,
                admit: activity.enabled,
                scope: scope
            )
        }.map(\.name)
        defer { needsRefresh = true }
        guard !targets.isEmpty else { throw ChatError.unsupported(capability: "callAdmission") }
        let count = try await device.respondToWaitingParticipants(
            targets,
            admit: activity.enabled,
            bulk: bulk
        )
        try await check()
        guard count == ids.count
        else { throw ChatError.transport("Some waiting requests could not be confirmed.") }
    }

    private func isEligibleAdmissionTarget(
        _ device: MeetDeviceWire.Device,
        requested: Set<UUID>,
        admit: Bool,
        scope: AdmissionAccess
    ) -> Bool {
        guard !device.isDeleted, !device.isPresentation,
              let row = hostControls.waitingParticipants[device.name],
              requested.contains(row.id) else { return false }
        if !admit {
            return row.canDeny && device.joinState == 3
        }
        if let warning = waitingWarning(device), warning != row.warning {
            return false
        }
        return scope.canAdmit(device.joinState)
    }

    private func waitingWarning(_ device: MeetDeviceWire.Device) -> CallWaitingParticipant.Warning? {
        guard device.joinState == 3, let reason = device.knockWarningReason, reason != 0 else { return nil }
        switch reason {
        case 1: return .suspiciousUser
        case 2: return .suspectedBot
        default: return .potentialRisk
        }
    }
}
