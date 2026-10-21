import ChatKit
import Foundation

struct ResourceSyncAddress: Hashable {
    let resource: ResourceSyncStatus.Resource
    let conversation: Conversation.ID?
}

extension AccountRuntime {
    func recordResourceSync(_ status: ResourceSyncStatus) throws {
        let key = ResourceSyncAddress(resource: status.resource, conversation: status.conversationID)
        if status.phase == .ready {
            guard resourceSync[key] != nil else { return }
        } else if resourceSync[key] == status {
            return
        }
        try appendAndPublish(.resourceSyncChanged(status), live: false)
    }

    func resourceSyncCommitted(_ status: ResourceSyncStatus) {
        let key = ResourceSyncAddress(resource: status.resource, conversation: status.conversationID)
        resourceSync[key] = status.phase == .ready ? nil : status
    }
}
