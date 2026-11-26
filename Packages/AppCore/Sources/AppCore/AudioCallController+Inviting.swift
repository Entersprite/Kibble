import ChatKit
import Foundation

public extension AudioCallController {
    func inviteToCall(_ member: Member.ID) async throws {
        guard let call, call.phase == .connected, interaction?.canInvite == true,
              !isEnding, inviteTask == nil, let interactions = service as? any CallInteractionService else {
            throw CancellationError()
        }
        let epoch = generation
        let task = Task { try await interactions.inviteToCall(member, callID: call.id) }
        inviteTask = task
        defer {
            if generation == epoch {
                inviteTask = nil
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == epoch,
              self.call?.id == call.id else { throw CancellationError() }
    }
}
