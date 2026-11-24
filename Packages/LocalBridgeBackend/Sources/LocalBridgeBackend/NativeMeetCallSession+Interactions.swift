import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func invite(callee: String) async throws {
        guard ready, !closed, connection == nil else { throw MeetDeviceSessionError.notJoined }
        let task = Task { try await performInvite(callee: callee) }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func performInvite(callee: String) async throws {
        // A background read must not consume an explicit Ring click as busy.
        // Mark the invitation operation in flight first, then settle that read.
        _ = await refresh?.result
        try await check()
        guard ready, !closed, await media.isConnected else { throw MeetDeviceSessionError.mediaNotConnected }
        try await validateAccount()
        await device.setMediaConnected(media.isConnected)
        try await device.invite(calleeID: callee, requestID: UUID())
        try Task.checkCancellation()
        lines.append("CreateMeetingInvite: accepted from Kibble's joined native device")
        ringingDeadline = now().advanced(by: .seconds(36))
        await publish(.ringing)
    }

    func sampleSpeakers() async {
        guard ready, !closed, !isSuspended, disconnectedAt == nil else { return }
        let levels = await media.remoteAudioLevels()
        guard !closed else { return }
        var speaking: [String: Bool] = [:]
        for sample in levels where sample.level.isFinite && (0 ... 1).contains(sample.level) {
            guard let name = participantAudioSources[sample.source] else { continue }
            let fresh = audioLevelTimes[sample.source].map { $0 != sample.timestamp } ?? false
            audioLevelTimes[sample.source] = sample.timestamp
            speaking[name] = (speaking[name] ?? false) || (fresh && sample.level >= 0.02)
        }
        audioLevelTimes = audioLevelTimes.filter { participantAudioSources[$0.key] != nil }
        guard participantSpeaking != speaking else { return }
        participantSpeaking = speaking
        await publishParticipants()
    }

    func setHandRaised(_ raised: Bool, expectedName: String? = nil) async throws {
        guard ready, !closed, connection == nil, !handOperation else { throw MeetDeviceSessionError.busy }
        handOperation = true
        defer { handOperation = false }
        let task = Task {
            _ = await refresh?.result
            try await check()
            let snapshot = try await device.collections()
            try await check()
            guard let local = await device.localDeviceName, let hands = snapshot.hands,
                  handVersion.map({ hands.version >= $0 }) ?? true else { throw MeetDeviceSessionError.busy }
            let currentName = hands.values.first(where: { $0.device == local })?.name
            applyHands(hands)
            if let expectedName {
                guard let roster = snapshot.devices,
                      roster.version >= max(deviceVersion ?? 0, participantVersion ?? 0),
                      currentName == expectedName, connectedOwnHand == expectedName,
                      roster.values.contains(where: {
                          $0.name == local && $0.joinState == 1 && !$0.isDeleted && !$0.isPresentation
                      }) else { return }
            }
            if !raised {
                requestedOwnLowering = currentName
                observedOwnHand = nil
                await clearAutomaticHandLowering()
                try await check()
            }
            guard expectedName == nil || (state == .active && !isSuspended && disconnectedAt == nil)
            else { return }
            _ = try await device.setHandRaised(raised, currentName: currentName)
            try await check()
            ownHandRaised = raised
            if !raised {
                participantHands?[local] = nil
            }
            needsRefresh = true
            await publishParticipants()
        }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func inviteParticipant(_ member: String) async throws {
        guard ready, !closed, connection == nil else { throw MeetDeviceSessionError.busy }
        let task = Task {
            _ = await refresh?.result
            try await check()
            try await device.inviteParticipant(calleeID: member)
            try await check()
        }
        connection = task
        defer { connection = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func publicInteraction() async -> CallInteractionState {
        let url = await device.publicJoinURL
        let dialIn = await device.publicDialInDetails(preferredRegion: Locale.current.region?.identifier)
        var result = CallInteractionState(
            joinURL: try? MeetJoinLink(url).url, canRaiseHand: true, canInvite: true
        )
        if result.joinURL != nil, let dialIn {
            let numbers = dialIn.numbers.map {
                CallDialIn(phoneNumber: $0.phoneNumber, pin: $0.pin, regionCode: $0.region)
            }
            result.dialIn = numbers.first
            if numbers.count > 1 {
                result.alternateDialIns = Array(numbers.dropFirst())
            }
            result.dialInNumbersURL = dialIn.directory
        }
        return result
    }
}

public extension MeetDMCallTrial {
    func setNativeHandRaised(_ raised: Bool, scope: UUID) async throws {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        try await session.setHandRaised(raised)
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
    }

    func inviteNativeParticipant(_ member: String, scope: UUID) async throws {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        try await session.inviteParticipant(member)
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
    }

    func nativeJoinURL(scope: UUID) async -> URL? {
        try? await nativeInteraction(scope: scope).joinURL
    }
}

extension MeetDMCallTrial {
    func nativeInteraction(scope: UUID) async throws -> CallInteractionState {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        let interaction = await session.publicInteraction()
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
        return interaction
    }
}
