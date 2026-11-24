import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func sendActivityMessage(_ text: String, sequence: UInt64) async throws {
        let data = try MeetActivityDataWire.chat(text, sequence: sequence)
        let response = try await media.exchangeActivityData(channel: "meet_messages", data: data) {
            MeetActivityDataWire.isChatResponse($0, sequence: sequence)
        }
        let local = await device.localDeviceName
        try await check()
        let message: Data
        do {
            message = try MeetActivityDataWire.chatResponse(response, sequence: sequence)
        } catch {
            let shape = MeetActivityDataWire.chatResponseShape(response, sequence: sequence)
            lines.append("Native meeting chat: unconfirmed create; " + shape)
            throw error
        }
        observeMessageReceiptRevision(response, sequence: sequence)
        mergeActivityMessages([message], replacing: false, local: local)
        await receiveActivities?(activities)
    }

    func sendWaitingRoomMessage(_ text: String, sequence: UInt64) async throws {
        let data = try MeetActivityDataWire.chat(text, sequence: sequence, recipient: .waitingRoom)
        defer { needsRefresh = true }
        lines.append("Native waiting-room chat: checking the joined-device grant")
        let baseline = try await device.joinedActivityCollections(including: .messages)
        let local = await device.localDeviceName
        try await check()
        reconcileWaitingRoomChatGrant(baseline.hostAccess)
        guard !isSuspended, disconnectedAt == nil, canMessageWaitingRoom,
              let local, let access = baseline.hostAccess, access.canMessageWaitingRoom,
              access.version == hostControls.waitingRoomChatGrant?.version,
              access.version >= (participantVersion ?? 0) else {
            updateActivityAvailability()
            await receiveActivities?(activities)
            throw ChatError.unsupported(capability: "waitingRoomChat")
        }
        lines.append("Native waiting-room chat: joined-device grant confirmed")
        let response: Data
        do {
            response = try await media.exchangeActivityData(channel: "meet_messages", data: data) {
                MeetActivityDataWire.isChatResponse($0, sequence: sequence)
            }
        } catch CallMediaError.signalingTimedOut {
            try await confirmWaitingRoomMessage(text, sequence: sequence, sender: local, after: baseline)
            return
        }
        try await check()
        lines.append("Native waiting-room chat: matched a message-channel response")
        guard canMessageWaitingRoom else { throw ChatError.unsupported(capability: "waitingRoomChat") }
        let message = try MeetActivityDataWire.chatResponse(
            response,
            sequence: sequence,
            recipient: .waitingRoom
        )
        let body = try MeetActivityCollections.bytes(5, message)
        guard MeetActivityCollections.text(1, body) == text else {
            throw MeetCallWire.WireError.malformedResponse
        }
        observeMessageReceiptRevision(response, sequence: sequence)
        mergeWaitingRoomMessages([message], replacing: false)
        lines.append("Native waiting-room chat: addressed receipt confirmed")
        await receiveActivities?(activities)
    }

    private func observeMessageReceiptRevision(_ response: Data, sequence: UInt64) {
        if let revision = MeetActivityDataWire.chatCreateRevision(response, sequence: sequence),
           revision > (activityVersions[3] ?? 0) {
            activityVersions[3] = revision
        }
    }

    private func confirmWaitingRoomMessage(
        _ text: String, sequence: UInt64, sender: String, after baseline: MeetActivityCollections.Snapshot
    ) async throws {
        try await check()
        let current = try await device.joinedActivityCollections(including: .messages)
        try await check()
        guard canMessageWaitingRoom, current.hostAccess?.canMessageWaitingRoom == true,
              let version = current.versions[3], version > (baseline.versions[3] ?? 0),
              version >= (activityVersions[3] ?? 0), let messages = current.messages,
              let accessVersion = current.hostAccess?.version,
              accessVersion >= (hostControls.waitingRoomChatGrant?.version ?? 0),
              accessVersion >= (participantVersion ?? 0) else {
            throw ChatError.transport("The waiting-room message could not be confirmed.")
        }
        let candidates = messages.filter {
            guard MeetActivityDataWire.isWaitingRoomChatText($0),
                  MeetActivityCollections.text(2, $0) == sender,
                  let body = try? MeetActivityCollections.bytes(5, $0)
            else { return false }
            return MeetActivityCollections.text(1, body) == text
        }
        let matches = candidates.filter { MeetActivityCollections.number(3, $0) == sequence }
        guard matches.count == 1 else {
            if !candidates.isEmpty {
                lines
                    .append(
                        "Native waiting-room chat: roster read returned text without the matching sequence"
                    )
            }
            throw ChatError.transport("The waiting-room message could not be confirmed.")
        }
        await reconcileActivities(current)
        try await check()
        lines.append("Native waiting-room chat: addressed collection readback confirmed")
    }

    func reconcileWaitingRoomChatGrant(_ access: MeetActivityCollections.HostAccess?) {
        guard let access, hostControls.waitingRoomChatGrant.map({
            access.version > $0.version || (access.version == $0.version && !access.canMessageWaitingRoom)
        }) ?? true else { return }
        hostControls.waitingRoomChatGrant = (access.version, access.canMessageWaitingRoom)
    }

    func mergeWaitingRoomMessages(_ values: [Data], replacing: Bool) {
        var messages = replacing ? [] : activities.waitingRoomMessages ?? []
        for value in values.prefix(256) {
            guard MeetActivityDataWire.isWaitingRoomChatText(value),
                  let body = try? MeetActivityCollections.bytes(5, value),
                  let text = MeetActivityCollections.text(1, body),
                  let name = MeetActivityCollections.text(1, value) else { continue }
            let id = activityHandle(name, kind: "waitingRoomMessage")
            let device = MeetActivityCollections.text(2, value)
            let sender = device.flatMap { participantDevices[$0]?.displayName } ?? "Participant"
            let message = CallMeetingMessage(id: id, sender: sender, text: text)
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        activities.waitingRoomMessages = Array(messages.suffix(256))
        let ids = Set((activities.waitingRoomMessages ?? []).map(\.id))
        activityResources = activityResources
            .filter { $0.value.kind != "waitingRoomMessage" || ids.contains($0.key) }
    }

    func clearWaitingRoomMessages() {
        guard activities.waitingRoomMessages != nil else { return }
        activities.waitingRoomMessages = nil
        activityResources = activityResources.filter { $0.value.kind != "waitingRoomMessage" }
    }
}
