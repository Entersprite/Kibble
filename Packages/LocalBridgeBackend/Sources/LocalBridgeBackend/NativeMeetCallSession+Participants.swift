import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func takeReport() -> [String] {
        defer { lines.removeAll() }
        return lines
    }

    func setParticipantHandler(_ handler: (@Sendable ([CallParticipantDevice]?) async -> Void)?) {
        receiveParticipants = handler
    }

    func reconcileParticipants(_ devices: MeetCallCollectionsWire.Devices, local: String) async {
        guard participantVersion.map({ devices.version > $0 }) ?? true else { return }
        participantVersion = devices.version
        let joined = devices.values.filter { !$0.isDeleted && $0.joinState == 1 }
        guard joined.count <= 256 else { await publishParticipantsUnavailable(); return }
        let names = Set(joined.map(\.name))
        participantHandles = participantHandles.filter { names.contains($0.key) }
        participantMutes = participantMutes.filter { names.contains($0.key) }
        for name in names where participantHandles[name] == nil {
            participantHandles[name] = UUID()
        }
        participantDevices = Dictionary(uniqueKeysWithValues: joined.map { ($0.name, $0) })
        participantLocalDevice = local
        agendaGuestPresenceAliases = Set(devices.values.lazy
            .filter { !$0.isDeleted && !$0.isPresentation && [1, 3, 13].contains($0.joinState) }
            .flatMap(\.calendarGuestAliases))
        await publishParticipants()
        await publishAgendaGuests()
    }

    func recordParticipantAudio(
        _ reply: Data,
        context: MeetVideoStreamWire.Context,
        requestID: UInt64
    ) async {
        guard let audio = try? MeetVideoStreamWire.deviceAudio(
            from: reply,
            context: context,
            requestID: requestID
        )
        else {
            participantMutes = [:]; participantAudioSources = [:]; participantSpeaking =
                [:]; await publishParticipants(); return
        }
        let sources = audio.flatMap { value in value.sourceSSRCs.map { ($0, value.deviceName) } }
        let grouped = Dictionary(grouping: sources, by: { $0.0 })
        participantAudioSources = grouped.reduce(into: [:]) { result, pair in
            if pair.value.count == 1 {
                result[pair.key] = pair.value[0].1
            }
        }
        let byDevice = Dictionary(grouping: audio, by: \.deviceName)
        participantMutes = byDevice.reduce(into: [:]) { result, row in
            if row.value.count == 1, let muted = row.value.first?.muted {
                result[row.key] = muted
            }
        }
        await publishParticipants()
    }

    func publishParticipantsUnavailable() async {
        let hadParticipants = publishedParticipants != nil
        publishedParticipants = nil
        agendaGuestPresenceAliases = nil
        if !activities.waitingParticipants.isEmpty || activities.agendaGuests != nil {
            activities.waitingParticipants.removeAll()
            activities.agendaGuests = nil
            if !closed {
                await receiveActivities?(activities)
            }
        }
        guard hadParticipants, publishedParticipants == nil else { return }
        await receiveParticipants?(nil)
    }

    func publishParticipants() async {
        guard !closed, state != .stateUnavailable, state != .reconnecting,
              participantLocalDevice != nil else { return }
        let enabledWaitingRoom = hostControls.waitingRoomEnabled == true && !unavailableActivityFields
            .contains(1)
        let observedWaitingRoom = hostControls.waitingParticipants.values.contains(where: \.isInWaitingRoom)
        let offersWaitingRoom = activities.availableActions.contains("sendParticipantToWaitingRoom")
            && hostControls.waitingRoomEnabled != false && (enabledWaitingRoom || observedWaitingRoom)
        let offersBlock = activities.availableActions.contains("blockParticipant")
        let own = participantLocalDevice.flatMap { participantDevices[$0] }
        let participants = participantDevices.keys.sorted().compactMap { name -> CallParticipantDevice? in
            guard let device = participantDevices[name], let id = participantHandles[name] else { return nil }
            return CallParticipantDevice(
                id: id, displayName: device.displayName,
                parentID: device.primaryDevice.flatMap { participantHandles[$0] },
                isPresentation: device.isPresentation,
                isLocal: name == participantLocalDevice || device.primaryDevice == participantLocalDevice,
                microphoneMuted: participantMutes[name],
                handRaised: name == participantLocalDevice ? ownHandRaised ?? participantHands
                    .map { $0[name] != nil } : participantHands.map { $0[name] != nil },
                isSpeaking: participantSpeaking[name], role: device.isPresentation ? nil : device.role.map {
                    switch $0 {
                    case .host: .host
                    case .cohost: .cohost
                    case .participant: .participant
                    }
                },
                canSendToWaitingRoom: offersWaitingRoom && name != participantLocalDevice
                    && Self.isWaitingRoomTarget(device) ? true : nil,
                canBlockInMeeting: offersBlock && name != participantLocalDevice && !device.isPresentation
                    && !Self.sameMeetingUser(device, own) ? true : nil,
                isPinnedForEveryone: device.isPinnedForEveryone,
                handRaisedAt: participantHands?[name]?.raisedAt
            )
        }
        guard participants != publishedParticipants else { return }
        publishedParticipants = participants
        await receiveParticipants?(participants)
    }
}
