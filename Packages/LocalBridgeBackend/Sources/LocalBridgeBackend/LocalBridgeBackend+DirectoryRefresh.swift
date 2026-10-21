import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// One account-owned worker consumes profile targets from directory reads.
    func requestDirectoryProfiles(for conversations: [Conversation], using client: ProtoAPIClient) {
        for conversation in conversations {
            pendingDirectoryProfiles[conversation.id] = conversation
        }
        guard memberResolution == nil else { return }
        let generation = directoryGeneration
        memberResolution = Task { [weak self] in
            await self?.drainDirectoryProfiles(using: client, generation: generation)
        }
    }

    private func drainDirectoryProfiles(using client: ProtoAPIClient, generation: Int) async {
        defer {
            if generation == directoryGeneration {
                memberResolution = nil
            }
        }
        while !Task.isCancelled, generation == directoryGeneration, !pendingDirectoryProfiles.isEmpty {
            let conversations = Array(pendingDirectoryProfiles.values)
            pendingDirectoryProfiles.removeAll()
            await resolveAndEmitMembers(for: conversations, using: client)
        }
    }
}
