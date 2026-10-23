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
        await publishParticipants()
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
        else { participantMutes = [:]; await publishParticipants(); return }
        let byDevice = Dictionary(grouping: audio, by: \.deviceName)
        participantMutes = byDevice.reduce(into: [:]) { result, row in
            if row.value.count == 1, let muted = row.value.first?.muted {
                result[row.key] = muted
            }
        }
        await publishParticipants()
    }

    func publishParticipantsUnavailable() async {
        guard publishedParticipants != nil else { return }
        publishedParticipants = nil
        await receiveParticipants?(nil)
    }

    func publishParticipants() async {
        guard !closed, state != .stateUnavailable, state != .reconnecting,
              participantLocalDevice != nil else { return }
        let participants = participantDevices.keys.sorted().compactMap { name -> CallParticipantDevice? in
            guard let device = participantDevices[name], let id = participantHandles[name] else { return nil }
            return CallParticipantDevice(
                id: id, displayName: device.displayName,
                parentID: device.primaryDevice.flatMap { participantHandles[$0] },
                isPresentation: device.isPresentation,
                isLocal: name == participantLocalDevice || device.primaryDevice == participantLocalDevice,
                microphoneMuted: participantMutes[name]
            )
        }
        guard participants != publishedParticipants else { return }
        publishedParticipants = participants
        await receiveParticipants?(participants)
    }
}
