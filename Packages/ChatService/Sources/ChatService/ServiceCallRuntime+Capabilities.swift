import ChatKit

extension ServiceCallRuntime {
    func installCapabilities() async {
        let joining = source as? any ExistingAudioCallService
        let canJoin = await joining?.canJoinExistingCalls == true
        guard !stopped else { return }
        if canJoin {
            state.supportsExistingJoin = true
            publish()
        }
        let conversations = source as? any ConversationAudioCallService
        let canCall = await conversations?.canCallConversations == true
        guard !stopped else { return }
        if canCall {
            state.supportsConversationCalls = true
            publish()
        }
        if let links = source as? any MeetingLinkAudioCallService {
            let enabled = await links.canJoinMeetingLinks
            guard !stopped else { return }
            if enabled {
                state.supportsMeetingLinks = true
                state.meetingLinkHosts = await Array(links.meetingLinkHosts).sorted()
                guard !stopped else { return }
                publish()
            }
        }
    }
}
