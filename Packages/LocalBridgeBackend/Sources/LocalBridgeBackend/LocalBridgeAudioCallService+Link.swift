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

    public var canCreateMeetingLinks: Bool {
        !isStopping
    }

    public var canPreviewMeetingLinks: Bool {
        !isStopping
    }

    public func previewMeetingTitle(at url: URL) async throws -> String? {
        let link = try MeetJoinLink(url)
        let scope = sessionScope
        try await waitForCallContext { try checkSession(scope) }
        let title = try await trial.previewMeetingTitle(link)
        try checkSession(scope)
        return title
    }

    public func createMeetingLink() async throws -> URL {
        guard canCreateMeetingLinks, meetingLinkCreation == nil else { throw CancellationError() }
        let scope = sessionScope
        let creation = Task {
            try await self.waitForCallContext { try self.checkSession(scope) }
            return try await self.trial.createMeetingLink()
        }
        meetingLinkCreation = creation
        defer {
            if sessionScope == scope {
                meetingLinkCreation = nil
            }
        }
        let url = try await withTaskCancellationHandler { try await creation.value } onCancel: {
            creation.cancel()
        }
        try checkSession(scope)
        return url
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
        try await runOperation(id: callID, scope: scope, canWaitForAdmission: true) {
            try await self.waitForCallContext(callID: callID, scope: scope)
            let prepared = try await self.trial.prepareMeetingLink(link.url)
            try self.checkCall(callID, scope: scope)
            self.readMeetingAgenda(preparedID: prepared.id, callID: callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
        }
    }

    private func readMeetingAgenda(preparedID: UUID, callID: UUID, scope: UUID) {
        meetingAgendaRead = Task { [weak self, trial] in
            let title = try? await trial.meetingAgendaTitle(preparedID: preparedID)
            guard let self, callScope == scope else { return }
            meetingAgendaRead = nil
            guard !Task.isCancelled, !isStopping, let title,
                  let call = conversationSnapshot, call.id == callID, !call.phase.isTerminal,
                  let url = call.target.meetingURL else { return }
            publishConversation(.init(
                id: call.id, target: .init(meetingURL: url, displayName: title),
                phase: call.phase, isMuted: call.isMuted,
                failureMessage: call.failureMessage, endReason: call.endReason, admission: call.admission
            ))
        }
    }

    func cancelMeetingAgendaRead() {
        meetingAgendaRead?.cancel()
        meetingAgendaRead = nil
        cancelWaitingRoomAgendaRead()
    }

    func readWaitingRoomAgenda(at url: URL, callID: UUID, scope: UUID) {
        waitingRoomAgendaRead = Task { [weak self, trial] in
            guard let attachments = try? await trial.waitingRoomAttachments(scope: scope),
                  !attachments.isEmpty,
                  let self, !Task.isCancelled, conversationSnapshot?.target.meetingURL == url else { return }
            updateWaitingRoomActivities(callID: callID, scope: scope) {
                $0.agendaAttachments = attachments
            }
        }
    }

    func updateWaitingRoomActivities(
        callID: UUID, scope: UUID, update: (inout CallActivitiesState) -> Void
    ) {
        guard !isStopping, callScope == scope, let call = conversationSnapshot,
              call.id == callID, call.phase == .connecting, call.admission == .waitingRoom else { return }
        var activities = waitingRoomActivities ?? CallActivitiesState()
        update(&activities)
        guard activities != waitingRoomActivities else { return }
        waitingRoomActivities = activities
        var interaction = CallInteractionState(joinURL: call.target.meetingURL)
        interaction.activities = activities
        continuation.yield(.interactionChanged(callID: callID, state: interaction))
    }

    func cancelWaitingRoomAgendaRead() {
        waitingRoomAgendaRead?.cancel()
        waitingRoomAgendaRead = nil
        waitingRoomActivities = nil
    }
}
