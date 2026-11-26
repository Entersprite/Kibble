import ChatKit
import GChatBridgeCore

enum MessageActivityMapping {
    static func pin(in annotations: [Annotation])
        -> (activity: MessageActivity, sender: ChatKit.Member.ID?)? {
        for annotation in annotations {
            guard case let .roomUpdated(update)? = annotation.metadata,
                  update.boardAction.action == 1
            else { continue }
            let activity: MessageActivity
            switch update.boardAction.targetType {
            case 1: activity = .pinnedMessage
            case 2: activity = .pinnedResource
            default: continue
            }
            let actor = update.initiator.userID.id
            return (activity, actor.isEmpty ? nil : .init(actor))
        }
        return nil
    }
}
