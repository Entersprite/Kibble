import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func check() async throws {
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        try await validateAccount()
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
    }

    func startMonitoring(
        receive: @escaping @Sendable (MeetNativeCallState) async -> Void,
        remoteMuted: (@Sendable (Bool?) async -> Void)? = nil
    ) async {
        guard ready, !closed, monitor == nil else { return }
        receiveState = receive
        receiveRemoteMuted = remoteMuted
        await media.setEventHandler { [weak self] event in await self?.mediaEvent(event) }
        await receive(state)
        guard !closed else { return }
        // A search can answer before anyone listens; unknown needs no delivery.
        if let remoteAudioMuted {
            await remoteMuted?(remoteAudioMuted)
        }
        guard !closed else { return }
        monitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                ticks += 1
                await sampleSpeakers()
                if ticks % 4 == 0 {
                    await monitorTick()
                }
            }
        }
    }

    func mediaEvent(_ event: CallMediaEvent) async {
        guard ready, !closed else { return }
        switch event {
        case let .activityData(channel, data): await receiveActivityData(channel: channel, data: data)
        case let .activityClosed(channel): await handleActivityChannelClosed(channel)
        case .collectionsChanged: needsRefresh = true
        case .connected:
            disconnectedAt = nil
            needsRefresh = true
            if !isSuspended {
                await publish(stableState)
            }
        case .disconnected:
            disconnectedAt = disconnectedAt ?? now()
            await publish(.reconnecting)
        case .failed: await closeAfterTransportLoss()
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
                await closeAfterTransportLoss()
            }
            return
        }
        // Polling also recovers notifications missed during channel setup.
        pollTicks += 1
        if needsRefresh || pollTicks >= 3 {
            pollTicks = 0
            await refreshState()
        }
        await updateAutomaticHandLowering()
        guard !closed else { return }
        if let ringingDeadline, now() >= ringingDeadline, !peerJoined {
            await close(reason: .ringingTimedOut)
        }
    }

    private func closeAfterTransportLoss() async {
        guard localObserved, connection == nil else { await close(reason: .transportFailed); return }
        let failure = disconnectedAt ?? now()
        disconnectedAt = failure
        guard refresh == nil else { return }
        let probe = Task { [device] in
            try await check()
            return try await device.collections(timeout: .seconds(2))
        }
        refresh = probe
        let result = await probe.result
        refresh = nil
        guard !closed else { return }
        if case let .failure(error) = result, error as? MeetDeviceSessionError == .conferenceEnded {
            // The provider already settled this registration, even if media reconnected.
            await close(reason: .conferenceEnded)
            return
        }
        guard disconnectedAt == failure else { return }
        let local = await device.localDeviceName
        guard !closed, disconnectedAt == failure else { return }
        if let roster = (try? result.get())?.devices, roster.version > (deviceVersion ?? 0),
           roster.version >= (participantVersion ?? 0),
           let own = roster.values.first(where: { $0.name == local }),
           let reason = confirmedDeviceEndReason(for: own) {
            await device.observeRemovedDevice(own)
            await close(reason: reason)
        } else {
            await close(reason: .transportFailed)
        }
    }

    func refreshState() async {
        guard ready, !closed, connection == nil, refresh == nil,
              !hostControls.remoteMute.isApplying else { return }
        do {
            try await validateAccount()
            guard ready, !closed, refresh == nil, connection == nil,
                  !hostControls.remoteMute.isApplying else { return }
            let task = Task { [device] in try await device.collections() }
            refresh = task
            let result = await task.result
            refresh = nil
            let snapshot = try result.get()
            try await validateAccount()
            guard !closed else { return }
            needsRefresh = false
            await reconcile(snapshot)
            if !closed, let devices = snapshot.devices, devices.version == verifiedDeviceVersion {
                if state == .stateUnavailable {
                    await publish(stableState)
                }
                await startJoinCameraIfReady()
            }
        } catch {
            guard !closed else { return }
            if error is MeetDMCallTrialError {
                await close(reason: .accountChanged)
            } else if error as? MeetDeviceSessionError == .conferenceEnded {
                await close(reason: .conferenceEnded)
            } else if error as? MeetDeviceSessionError != .busy {
                lines.append("Native call state: collection check unavailable; "
                    + MeetDMCallTrial.errorDescription(error))
                await publish(.stateUnavailable)
            }
        }
    }

    private func reconcile(_ snapshot: MeetCallCollectionsWire.Snapshot) async {
        if let activities = snapshot.activities {
            await reconcileActivities(activities)
        }
        await reconcileHands(snapshot)

        if let devices = snapshot.devices {
            await reconcileDeviceSnapshot(devices)
        }
        await publishParticipants()
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

    private func reconcileDeviceSnapshot(_ devices: MeetCallCollectionsWire.Devices) async {
        guard let local = await device.localDeviceName, !closed,
              devices.version >= max(deviceVersion ?? 0, participantVersion ?? 0) else { return }
        if let own = devices.values.first(where: { $0.name == local && !$0.isDeleted && $0.joinState == 1 }),
           devices.version != deviceVersion || (hostControls.remoteMute.needsAcknowledgement
               && own.audioMuteRequester == hostControls.remoteMute.requester) {
            await receiveRemoteMute(own.audioMuteRequester)
        }
        guard !closed, deviceVersion.map({ devices.version > $0 }) ?? true else { return }
        await reconcileDevices(devices, local: local)
    }

    private func reconcileDevices(_ devices: MeetCallCollectionsWire.Devices, local: String) async {
        deviceVersion = devices.version
        verifiedAloneDeviceVersion = nil
        let own = devices.values.first { $0.name == local }
        if own == nil, localObserved {
            lines.append("Native device roster: joined local device absent from full snapshot")
            await close(reason: .deviceEnded)
            return
        }
        guard let own else { await publish(.stateUnavailable); return }
        localObserved = true
        if own.isDeleted || [4, 5, 6, 7, 8, 11].contains(own.joinState) {
            let reason = own.finalStateReason.map(String.init) ?? "unknown"
            let status = "join state=\(own.joinState) deleted=\(own.isDeleted) reason=\(reason)"
            lines.append("Native device roster: " + status)
            await device.observeRemovedDevice(own)
            await close(reason: confirmedDeviceEndReason(for: own) ?? .deviceEnded)
            return
        }
        guard own.joinState == 1 else { await publish(.stateUnavailable); return }
        await updateDeviceCaptionLanguages(own.captionLanguages)
        guard !closed else { return }
        await reconcileParticipants(devices, local: local)
        guard !closed else { return }
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
        } else if staysWhenAlone {
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

    private func confirmedDeviceEndReason(for own: MeetDeviceWire.Device) -> MeetNativeCallEndReason? {
        if own.wasTransferredOut {
            return .switchedDevice
        }
        if own.wasEndedByHost {
            return .conferenceEnded
        }
        if own.wasSentToWaitingRoom {
            return .sentToWaitingRoom
        }
        if own.wasRemoved {
            return .removedFromMeeting
        }
        if own.wasRejectedAsIncompatible {
            return .incompatibleClient
        }
        return own.isDeleted ? .deviceEnded : nil
    }

    func publish(_ next: MeetNativeCallState) async {
        let mediaInterrupted = isSuspended || disconnectedAt != nil
        switch next {
        case .ready, .ringing, .active:
            // A collection read can finish during an interruption. Keep its
            // verified phase for recovery while the media state stays visible.
            stableState = next
            guard !mediaInterrupted else { return }
        case .stateUnavailable where mediaInterrupted: return
        default: break
        }
        guard next != state else { return }
        state = next
        switch next {
        case .stateUnavailable, .reconnecting, .ended, .endedUnconfirmed:
            observedOwnHand = nil
            await clearAutomaticHandLowering()
            await publishParticipantsUnavailable()
        case .ready, .ringing, .active:
            await publishParticipants()
        default: break
        }
        guard state == next else { return }
        lines.append("Native call state: " + next.message)
        if lines.count > 256 {
            lines.removeFirst(lines.count - 256)
        }
        await receiveState?(next)
    }
}
