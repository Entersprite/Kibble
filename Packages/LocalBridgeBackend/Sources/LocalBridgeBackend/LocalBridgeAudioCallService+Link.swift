import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeAudioCallService: MeetingLinkAudioCallService {
    public var meetingLinkHosts: Set<String> {
        ["meet.google.com"]
    }

    public func normalizedMeetingLink(_ url: URL) throws -> URL {
        try MeetJoinLink(url).url
    }

    public var canJoinMeetingLinks: Bool {
        true
    }

    public func joinMeeting(at url: URL, callID: UUID) async throws {
        let link = try MeetJoinLink(url)
        guard !hasCall, operation == nil, !isStopping else {
            throw ChatError.unsupported(capability: "meetingLinks")
        }
        callScope = UUID()
        muteSequence = 0
        incomingHandle = nil
        snapshot = nil
        publishConversation(.init(
            id: callID, target: .init(meetingURL: link.url, displayName: "Meeting"), phase: .connecting
        ))
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            try await self.waitForCallContext(callID: callID, scope: scope)
            let prepared = try await self.trial.prepareMeetingLink(link.url)
            try self.checkCall(callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
        }
    }
}
