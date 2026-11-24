import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
    func createMeetingLink() async throws -> URL {
        guard let context else { throw MeetDMCallTrialError.signedOut }
        try await ensureCurrent(context.stored)
        let client = try await loadCallClient(context)
        try await ensureMeetingLinkContext(context)
        let url = try await client.createMeetingLink()
        try await ensureMeetingLinkContext(context)
        return url
    }

    private func ensureMeetingLinkContext(_ expected: Context) async throws {
        try await ensureCurrent(expected.stored)
        try Task.checkCancellation()
        guard context?.credentials === expected.credentials else { throw MeetDMCallTrialError.superseded }
    }

    internal func previewMeetingTitle(_ link: MeetJoinLink) async throws -> String? {
        guard let context else { throw MeetDMCallTrialError.signedOut }
        try await ensureMeetingLinkContext(context)
        let client = try await loadCallClient(context)
        try await ensureMeetingLinkContext(context)
        let call = try await client.resolveExisting(code: link.code)
        try await ensureMeetingLinkContext(context)
        guard (try? MeetJoinLink(call.space.url)) == link else { return nil }
        let title = try await client.fetchMeetingAgendaTitle(call)
        try await ensureMeetingLinkContext(context)
        return title
    }

    internal func meetingAgendaTitle(preparedID: UUID) async throws -> String? {
        guard let prepared, prepared.ticket == preparedID else { return nil }
        try await ensureMeetingLinkContext(prepared.context)
        try ensureGeneration(prepared.generation)
        guard self.prepared?.ticket == preparedID else { return nil }
        let title = try await prepared.client.fetchMeetingAgendaTitle(prepared.call)
        try await ensureMeetingLinkContext(prepared.context)
        try ensureGeneration(prepared.generation)
        return self.prepared?.ticket == preparedID ? title : nil
    }

    func prepareMeetingLink(_ url: URL) async throws -> PreparedMeetDMCall {
        let link = try MeetJoinLink(url)
        await endNativeCall()
        prepared = nil
        generation += 1
        let current = generation
        lines.append("Meeting link preparation: checking the current account")
        do {
            guard let context else { throw MeetDMCallTrialError.signedOut }
            try await ensureCurrent(context.stored)
            try ensureGeneration(current)
            let client = try await loadCallClient(context, generation: current)
            lines.append("ResolveMeetingSpace: public meeting link started (value withheld)")
            let call = try await client.resolveExisting(code: link.code)
            lines.append("ResolveMeetingSpace: public meeting link accepted (value withheld)")
            try await ensureCurrent(context.stored)
            try ensureGeneration(current)
            let ticket = UUID()
            prepared = Prepared(
                ticket: ticket, generation: current, target: nil,
                context: context, client: client, call: call, ownerReportedBrowserJoin: false,
                permitsInvitation: false, isConversationCall: true
            )
            return PreparedMeetDMCall(id: ticket, url: call.space.url)
        } catch {
            if generation == current {
                lines.append("Meeting link preparation: " + Self.errorDescription(error))
            }
            throw error
        }
    }
}
