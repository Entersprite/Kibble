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
        case ReadCallState.operation, ControlCall.operation:
            guard let context else { throw ServiceFailure.notAuthorized }
            return try await dispatchCalls(request, context: context, backend: backend, epoch: epoch)
        case BeginDownloadTransfer.operation, GetDownloadTransfer.operation:
            return try await dispatchDownload(request, backend: backend, context: context, epoch: epoch)
        case BeginUploadTransfer.operation, GetUploadTransfer.operation,
             FinalizeUploadTransfer.operation, CancelTransfer.operation:
            return try await dispatchUpload(request, backend: backend, context: context, epoch: epoch)
        case GetCapabilities.operation, LoadConversations.operation, LoadMessages.operation,
             SearchPeople.operation, SearchMessages.operation, LoadFollowedThreads.operation:
            return try await dispatchQueries(request, backend: backend, epoch: epoch)
        case GetConversationDetails.operation, GetParticipants.operation, BrowseSpaces.operation,
             GetConversationPreview.operation, GetMembership.operation, LoadThread.operation,
             SetNotificationSetting.operation,
             SetThreadFollowed.operation:
            return try await dispatchDetails(request, backend: backend, epoch: epoch)
        case OpenDirectConversation.operation, CreateConversation.operation, MutateConversation.operation,
             SendCommand.operation, SendHint.operation, InvokeCardAction.operation:
            return try await dispatchMutations(request, backend: backend, context: context, epoch: epoch)
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    func installedCapabilities(from backend: any ChatBackend) -> Capabilities {
        var capabilities = backend.capabilities
        if !(backend is any BoundedMediaBackend) || !(transferStorage is any ServiceDownloadStorage) ||
            !(storage is any ServiceMediaCatalog) {
            capabilities.canFetchAttachments = false
            capabilities.canDownloadFiles = false
            capabilities.canFetchCustomEmoji = false
            capabilities.canFetchRemoteImages = false
        }
        if transferStorage == nil || !(storage is any ServiceUploadReferences) {
            capabilities.canSendAttachments = false
        } else {
            capabilities.maximumAttachmentBytes = min(
                capabilities.maximumAttachmentBytes ?? transferLimits.maximumFileBytes,
                transferLimits.maximumFileBytes
            )
        }
        return capabilities
    }
}
