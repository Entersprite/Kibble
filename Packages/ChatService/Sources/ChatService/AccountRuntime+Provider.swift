import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchProvider(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        context: ServiceSessionContext?,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case BeginDownloadTransfer.operation, GetDownloadTransfer.operation:
            return try await dispatchDownload(request, backend: backend, context: context, epoch: epoch)
        case BeginUploadTransfer.operation, FinalizeUploadTransfer.operation, CancelTransfer.operation:
            return try await dispatchUpload(request, backend: backend, context: context, epoch: epoch)
        case GetCapabilities.operation, LoadConversations.operation, LoadMessages.operation,
             SearchPeople.operation, SearchMessages.operation, LoadFollowedThreads.operation:
            return try await dispatchQueries(request, backend: backend, epoch: epoch)
        case GetConversationDetails.operation, GetParticipants.operation, BrowseSpaces.operation,
             GetMembership.operation, LoadThread.operation, SetNotificationSetting.operation,
             SetThreadFollowed.operation:
            return try await dispatchDetails(request, backend: backend, epoch: epoch)
        case OpenDirectConversation.operation, CreateConversation.operation, MutateConversation.operation,
             SendCommand.operation, SendHint.operation:
            return try await dispatchMutations(request, backend: backend, context: context, epoch: epoch)
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
