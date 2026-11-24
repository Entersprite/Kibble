import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    struct RemoteMuteState {
        var requester: String?
        var isApplying = false
        var needsAcknowledgement = false
    }

    func receiveRemoteMute(_ requester: String?) async {
        guard !hostControls.remoteMute.isApplying else { return }
        if requester != hostControls.remoteMute.requester {
            hostControls.remoteMute.requester = requester
            hostControls.remoteMute.needsAcknowledgement = requester != nil
            if requester != nil {
                await applyRemoteMute()
            }
        }
        guard requester != nil, hostControls.remoteMute.needsAcknowledgement else { return }
        hostControls.remoteMute.needsAcknowledgement = false
        do {
            try await check()
            try await device.acknowledgeRemoteMute()
        } catch MeetDeviceSessionError.busy {
            // The device slot refused admission before sending the clear.
            if hostControls.remoteMute.requester == requester {
                hostControls.remoteMute.needsAcknowledgement = true
            }
        } catch {
            if !closed {
                lines.append("Native microphone: remote mute acknowledgement unconfirmed")
            }
        }
    }

    private func applyRemoteMute() async {
        hostControls.remoteMute.isApplying = true
        defer { hostControls.remoteMute.isApplying = false }
        hostControls.microphoneInterruptionVersion += 1
        desiredMuted = true
        streamTask?.cancel()
        await media.setMuted(true)
        guard !closed else { return }
        synchronizeForcedMute()
        activities.moderatorMute = UUID()
        await receiveActivities?(activities)
    }

    func muteOtherParticipants(_ activity: CallActivity) async throws {
        let bulk = activity.action == "muteAllParticipants"
        guard activity.enabled, bulk == (activity.resourceID == nil) else {
            throw ChatError.unsupported(capability: "callRemoteMute")
        }
        let (local, devices) = try await verifyParticipantAction(activity.action)
        let targets = devices.values.filter { device in
            device.name != local && device.joinState == 1 && !device.isDeleted && !device.isPresentation
                && (bulk || participantHandles[device.name] == activity.resourceID)
        }.map(\.name).sorted()
        if bulk, targets.isEmpty {
            return
        }
        guard !targets.isEmpty else { throw ChatError.unsupported(capability: "callRemoteMute") }
        let accepted = try await device.muteParticipants(targets, bulk: bulk)
        try await check()
        needsRefresh = true
        guard accepted == targets.count
        else { throw ChatError.transport("Some participants could not be muted.") }
    }
}
