import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
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
