import ChatKit
import GChatBridgeCore

extension NativeMeetCallSession {
    func reconcileContinuousChat(_ snapshot: MeetActivityCollections.Snapshot) {
        if let access = snapshot.hostAccess,
           hostControls.continuousChatAccess.map({
               access.version > $0.version || (access.version == $0.version && !access.canUseContinuousChat)
           }) ?? true {
            hostControls.continuousChatAccess = (access.version, access.canUseContinuousChat)
        }
        if let version = snapshot.versions[1], let space = snapshot.space {
            let group = MeetActivityWire.continuousChatGroup(in: space)
                .flatMap(Self.continuousChatConversation)
            if activityVersions[1].map({ version > $0 }) ?? true {
                hostControls.continuousChatGroup = group
            } else if version == activityVersions[1], group != hostControls.continuousChatGroup {
                hostControls.continuousChatGroup = nil
            }
        }
    }

    func updateContinuousChatRoute() {
        guard hostControls.continuousChatAccess?.eligible == true, !unavailableActivityFields.contains(1),
              let id = hostControls.continuousChatGroup else {
            activities.meetingChat = nil
            return
        }
        activities.meetingChat = CallMeetingChat(conversationID: id, canSend: canSendMeetingChat)
    }

    private static func continuousChatConversation(_ groupID: String) -> Conversation.ID? {
        var space = SpaceId()
        space.spaceID = groupID
        var group = GroupId()
        group.spaceID = space
        return ChannelEventMapping.conversationID(group)
    }
}
