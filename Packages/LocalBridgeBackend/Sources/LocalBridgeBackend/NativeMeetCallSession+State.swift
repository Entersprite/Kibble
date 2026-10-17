import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func startMonitoring(receive: @escaping @Sendable (MeetNativeCallState) async -> Void) async {
        guard ready, !closed, monitor == nil else { return }
        receiveState = receive
        await media.setEventHandler { [weak self] event in await self?.mediaEvent(event) }
        await receive(state)
        guard !closed else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await monitorTick()
            }
        }
    }

    func mediaEvent(_ event: CallMediaEvent) async {
        guard ready, !closed else { return }
        switch event {
        case .collectionsChanged: needsRefresh = true
        case .connected:
            disconnectedAt = nil
            needsRefresh = true
            if !isSuspended {
                await publish(stableState)
            }
        case .disconnected:
            if disconnectedAt == nil {
                disconnectedAt = now()
            }
            await publish(.reconnecting)
        case .failed: await close(reason: .transportFailed)
        case .suspended:
            isSuspended = true
            await publish(.reconnecting)
        case .resumed: await resumeMedia()
        }
    }

    private func resumeMedia() async {
        guard isSuspended else { return }
        isSuspended = false
        let connected = await media.isConnected
        guard ready, !closed else { return }
        disconnectedAt = connected ? nil : now()
        needsRefresh = true
        await publish(connected ? stableState : .reconnecting)
    }

    func monitorTick() async {
        guard ready, !closed, !isSuspended, connection == nil else { return }
        if let disconnectedAt {
            if now() - disconnectedAt >= .seconds(15) {
                await close(reason: .transportFailed)
            }
            return
        }
        // Polling also recovers notifications missed during channel setup.
        pollTicks += 1
        if needsRefresh || pollTicks >= 3 {
            pollTicks = 0
            await refreshState()
        }
        guard !closed else { return }
        if let ringingDeadline, now() >= ringingDeadline, !peerJoined {
            await close(reason: .ringingTimedOut)
        }
    }

    func refreshState() async {
        guard ready, !closed, connection == nil, refresh == nil else { return }
        do {
            try await validateAccount()
            guard ready, !closed, refresh == nil, connection == nil else { return }
            let task = Task { [device] in try await device.collections() }
            refresh = task
            let snapshot: MeetCallCollectionsWire.Snapshot
            do { snapshot = try await task.value } catch { refresh = nil; throw error }
            refresh = nil
            try await validateAccount()
            guard !closed else { return }
            needsRefresh = false
            await reconcile(snapshot)
            if !closed, let devices = snapshot.devices, devices.version == verifiedDeviceVersion,
               state == .stateUnavailable {
                await publish(stableState)
            }
        } catch {
            guard !closed else { return }
            if error is MeetDMCallTrialError {
                await close(reason: .accountChanged)
            } else if error as? MeetDeviceSessionError != .busy {
                lines.append("Native call state: collection check unavailable; "
                    + MeetDMCallTrial.errorDescription(error))
                await publish(.stateUnavailable)
            }
        }
    }

    private func reconcile(_ snapshot: MeetCallCollectionsWire.Snapshot) async {
        if let devices = snapshot.devices, deviceVersion.map({ devices.version > $0 }) ?? true,
           let local = await device.localDeviceName {
            await reconcileDevices(devices, local: local)
        }
        guard !closed else { return }
        if let invitations = snapshot.invitations,
           invitationVersion.map({ invitations.version > $0 }) ?? true,
           let id = await device.outgoingInvitationID {
            invitationVersion = invitations.version
            if let invitation = invitations.values.first(where: { $0.id == id }) {
                invitationSeen = true
                outgoingInvitationStatus = invitation.status
            } else if invitationSeen, !peerJoined {
                await device.completeInvitation()
                await close(reason: .invitationEnded)
            }
        }
        guard !closed, !peerJoined, ringingDeadline != nil, outgoingInvitationStatus == 7,
              let devices = snapshot.devices, devices.version == verifiedAloneDeviceVersion else { return }
        // Meet's caller ends when every own invitation is declined and only
        // the caller device remains. This DM trial has one retained invitation.
        await device.completeInvitation()
        await close(reason: .declined)
    }

    private func reconcileDevices(_ devices: MeetCallCollectionsWire.Devices, local: String) async {
        deviceVersion = devices.version
        verifiedAloneDeviceVersion = nil
        let own = devices.values.first { $0.name == local }
        if own == nil, localObserved {
            await close(reason: .deviceEnded)
            return
        }
        guard let own else { await publish(.stateUnavailable); return }
        localObserved = true
        if own.isDeleted || [4, 5, 6, 7, 8, 11].contains(own.joinState) {
            await close(reason: .deviceEnded)
            return
        }
        guard own.joinState == 1 else { await publish(.stateUnavailable); return }
        verifiedDeviceVersion = devices.version
        let others = devices.values.filter { $0.name != local && !$0.isDeleted && !$0.isPresentation }
        if others.isEmpty {
            verifiedAloneDeviceVersion = devices.version
        }
        let joined = others.contains { $0.joinState == 1 }
        if joined {
            peerJoined = true
            ringingDeadline = nil
            await device.completeInvitation()
            await publish(.active)
        } else if peerJoined {
            // A full snapshot is authoritative. A delta or failed request
            // is never interpreted as an empty peer list.
            await close(reason: .remoteEnded)
            return
        } else {
            await publish(ringingDeadline == nil ? .ready : .ringing)
        }
    }

    func publish(_ next: MeetNativeCallState) async {
        guard next != state else { return }
        state = next
        switch next {
        case .ready, .ringing, .active: stableState = next
        default: break
        }
        lines.append("Native call state: " + next.message)
        if lines.count > 256 {
            lines.removeFirst(lines.count - 256)
        }
        await receiveState?(next)
    }
}
