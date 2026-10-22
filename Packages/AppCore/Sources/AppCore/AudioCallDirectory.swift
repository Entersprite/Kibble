import ChatKit
import Foundation
import SyncEngine

extension AppEnvironment {
    func startCalls(service: (any AudioCallService)?, model: ChatSessionModel) {
        calls.start(service: service, directory: {
            AudioCallRecipient.directory(
                conversations: model.conversations, members: model.directory, me: model.me
            )
        })
    }
}
