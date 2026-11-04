import ChatKit
import Foundation

extension AudioCallController {
    func receive(_ event: AudioCallEvent) {
        switch event {
        case let .recipientsChanged(values):
            recipients = values.reduce(into: [:]) { $0[$1.conversationID] = $1 }
        case let .listenerChanged(isListening):
            listenerFailure = isListening ? nil : "Incoming calls are unavailable."
        case let .snapshot(snapshot):
            receiveSnapshot(AudioCallSession(snapshot, isJoining: joining(snapshot.id)))
        case let .conversationSnapshot(snapshot), let .meetingSnapshot(snapshot):
            receiveSnapshot(AudioCallSession(snapshot, isJoining: joining(snapshot.id)))
        case let .participantsChanged(callID, devices):
            guard call?.id == callID, call?.phase.isTerminal == false, !retiredIDs.contains(callID)
            else { break }
            participants = devices
        case let .interactionChanged(callID, state):
            guard call?.id == callID, call?.phase.isTerminal == false,
                  !retiredIDs.contains(callID) else { break }
            interaction = state
        case .unknown, .listenerBarrier: break
        }
        refreshSupport()
    }

    private func joining(_ id: UUID) -> Bool {
        call?.id == id && call?.isJoining == true
    }

    func refreshSupport() {
        let links = service as? any MeetingLinkAudioCallService
        supportsMeetingLinks = links?.canJoinMeetingLinks == true
        supportedMeetingLinkHosts = supportsMeetingLinks ? links?.meetingLinkHosts ?? [] : []
        let join = existingJoinService?.canJoinExistingCalls ?? false
        let conversations = conversationService?.canCallConversations ?? false
        if supportsExistingJoin != join {
            supportsExistingJoin = join
        }
        if supportsConversationCalls != conversations {
            supportsConversationCalls = conversations
        }
    }

    private func receiveSnapshot(_ snapshot: AudioCallSession) {
        if receiveTerminalSnapshot(snapshot) {
            return
        }
        guard !retiredIDs.contains(snapshot.id) else { return }
        if call?.id == snapshot.id {
            guard call?.phase.isTerminal == false, !isEnding else { return }
            call = snapshot
            if snapshot.phase.isTerminal {
                retire(snapshot.id)
            }
        } else if snapshot.recipient != nil, snapshot.direction == .incoming, snapshot.phase == .incoming,
                  call == nil || call?.phase.isTerminal == true, !isEnding {
            call = snapshot
            participants = nil
            interaction = nil
            windowRequests += 1
        }
    }

    private func receiveTerminalSnapshot(_ snapshot: AudioCallSession) -> Bool {
        guard call?.id == snapshot.id, snapshot.phase.isTerminal else { return false }
        sourceTermination = snapshot
        if isEnding {
            endingSnapshot = snapshot
            return true
        }
        // Terminal information can arrive after the awaited operation returns.
        // Refining the same terminal phase cannot reactivate a retired call.
        guard call?.phase == snapshot.phase else { return false }
        call = snapshot
        return true
    }

    /// A finished call keeps no roster: nobody shown is still in it.
    private func retire(_ id: UUID) {
        retiredIDs.insert(id)
        operationTask?.cancel()
        muteTask?.cancel()
        interactionTask?.cancel()
        activityTask?.cancel()
        activityTask = nil
        inviteTask?.cancel()
        inviteTask = nil
        interactionTask = nil
        isUpdatingInteraction = false
        isUpdatingMute = false
        participants = nil
        interaction = nil
    }
}
