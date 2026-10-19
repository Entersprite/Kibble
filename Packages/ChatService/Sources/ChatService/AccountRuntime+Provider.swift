import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchProvider(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetCapabilities.operation, LoadConversations.operation, LoadMessages.operation,
             SearchPeople.operation, SearchMessages.operation, LoadFollowedThreads.operation:
            return try await dispatchQueries(request, backend: backend, epoch: epoch)
        case GetConversationDetails.operation, GetParticipants.operation, BrowseSpaces.operation,
             GetMembership.operation, LoadThread.operation, SetNotificationSetting.operation,
             SetThreadFollowed.operation:
            return try await dispatchDetails(request, backend: backend, epoch: epoch)
        case OpenDirectConversation.operation, CreateConversation.operation, MutateConversation.operation,
             SendCommand.operation:
            return try await dispatchMutations(request, backend: backend, epoch: epoch)
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
