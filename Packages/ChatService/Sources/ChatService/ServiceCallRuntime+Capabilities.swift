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
            let canJoin = await links.canJoinMeetingLinks
            let canCreate = await links.canCreateMeetingLinks
            let canPreview = await links.canPreviewMeetingLinks
            let hosts = canJoin ? await Array(links.meetingLinkHosts).sorted() : []
            guard !stopped else { return }
            if canJoin {
                state.supportsMeetingLinks = true
                state.meetingLinkHosts = hosts
                if canPreview {
                    state.supportsMeetingLinkPreview = true
                }
            }
            if canCreate {
                state.supportsMeetingLinkCreation = true
            }
            if canJoin || canCreate {
                publish()
            }
        }
    }
}
