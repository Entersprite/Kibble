import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func refreshAgendaArtifacts() {
        guard ready, !closed, agendaArtifactRead == nil else { return }
        agendaArtifactRead = Task { [weak self] in
            await self?.loadAgendaArtifacts()
        }
    }

    private func loadAgendaArtifacts() async {
        defer { agendaArtifactRead = nil }
        do {
            try await check()
            let agenda = try await device.agendaFiles()
            try await check()
            let files = (agenda?.artifacts ?? []).map {
                CallArtifactFile(kind: $0.kind.rawValue, title: $0.title, url: $0.url)
            }
            let attachments = agenda.flatMap { agenda in
                agenda.attachments.isEmpty ? nil : agenda.attachments.map {
                    CallAgendaAttachment(title: $0.title, url: $0.url)
                }
            }
            agendaGuestRows = agenda?.guests ?? []
            let guests = projectAgendaGuests()
            guard activities.artifactFiles != files || activities.agendaAttachments != attachments
                || activities.agendaGuests != guests
            else { return }
            activities.artifactFiles = files
            activities.agendaAttachments = attachments
            activities.agendaGuests = guests
            await receiveActivities?(activities)
        } catch {
            guard !closed, !Task.isCancelled else { return }
            agendaGuestRows.removeAll()
            agendaGuestHandles.removeAll()
            await publishAgendaGuests()
        }
    }

    func publishAgendaGuests() async {
        guard !closed else { return }
        let guests = projectAgendaGuests()
        guard activities.agendaGuests != guests else { return }
        activities.agendaGuests = guests
        await receiveActivities?(activities)
    }

    private func projectAgendaGuests() -> [CallAgendaGuest]? {
        guard state != .stateUnavailable, state != .reconnecting, publishedParticipants != nil,
              let presenceAliases = agendaGuestPresenceAliases,
              let name = participantLocalDevice, let local = participantDevices[name],
              !local.isPresentation, !local.isAnonymous, local.meetingUserID != nil else { return nil }
        var handles: [String: UUID] = [:]
        let guests = agendaGuestRows.enumerated().compactMap { index, guest -> CallAgendaGuest? in
            let key = guest.alias ?? String(index)
            let id = agendaGuestHandles[key] ?? UUID()
            handles[key] = id
            guard !presenceAliases.contains(key) else { return nil }
            return CallAgendaGuest(
                id: id, displayName: guest.displayName, response: guest.response?.rawValue,
                isOptional: guest.isOptional, chatAddress: guest.chatAddress
            )
        }
        agendaGuestHandles = handles
        return guests.isEmpty ? nil : guests
    }
}
