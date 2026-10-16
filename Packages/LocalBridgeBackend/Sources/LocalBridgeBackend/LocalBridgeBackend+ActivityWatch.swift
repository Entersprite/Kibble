import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func watchActivity(_ command: ChatCommand) async {
        switch command {
        case let .watchPresence(members):
            watchPresence(members)
        case let .watchConversationActivity(id):
            // The account owns this channel; a disconnected hint is retried by the client.
            guard let channel else { return }
            let group = id.flatMap { ChannelEventMapping.groupID(for: $0) }
            await channel.watchGroup(group)
        default:
            break
        }
    }
}
