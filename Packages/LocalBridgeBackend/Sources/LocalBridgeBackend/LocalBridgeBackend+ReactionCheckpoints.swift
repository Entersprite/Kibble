import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// A reaction trigger requires an authoritative message read. Later posts
    /// in this group cannot checkpoint past that unfinished read.
    func deferReactionRevisions(_ event: ChannelEvent, proposed: ProviderCursorPatch) -> ProviderCursorPatch {
        for body in event.bodies {
            if let target = ChannelEventMapping.reactedMessage(in: body),
               let id = ChannelEventMapping.conversationID(target.parent.topicID.groupID) {
                delivery.reactionGroups[target.messageID] = id.rawValue
            }
        }
        var patch = proposed
        let pending = Set(delivery.reactionGroups.values)
        for (id, revision) in proposed.groups where pending.contains(id) {
            delivery.deferredRevisions[id] = max(delivery.deferredRevisions[id] ?? 0, revision)
            patch.groups[id] = nil
        }
        return patch
    }

    func finishReactionRevision(_ message: ChatKit.Message.ID) async {
        guard let group = delivery.reactionGroups.removeValue(forKey: message),
              !delivery.reactionGroups.values.contains(group), !delivery.recoveryIncomplete,
              let revision = delivery.deferredRevisions.removeValue(forKey: group) else { return }
        try? await submitProviderBatch(.init(patch: .init(groups: [group: revision])))
    }
}
