import ChatKit
import Foundation

extension LocalBridgeAudioCallService: ExistingAudioCallService {
    public var canJoinExistingCalls: Bool {
        true
    }

    public func joinExisting(to recipient: AudioCallRecipient, callID: UUID) async throws {
        guard !hasCall, operation == nil, !isStopping,
              let person = people.values.first(where: { Self.recipient($0) == recipient }) else {
            throw ChatError.unsupported(capability: "joinExistingAudioCall")
        }
        callScope = UUID()
        muteSequence = 0
        incomingHandle = nil
        let current = AudioCallSnapshot(
            id: callID, recipient: recipient, direction: .outgoing, phase: .connecting
        )
        conversationSnapshot = nil
        snapshot = current
        continuation.yield(.snapshot(current))
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            let prepared = try await self.trial.prepareExisting(person: person.id)
            try self.checkCall(callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
        }
    }
}
