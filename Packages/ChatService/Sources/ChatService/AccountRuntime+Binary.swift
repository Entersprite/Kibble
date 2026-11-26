import ChatAPI
import Foundation

extension AccountRuntime {
    func handleBinary(
        _ request: ServiceRequest, body: Data, context: ServiceSessionContext
    ) async throws -> ServiceBinaryFrame {
        guard !stopped else { throw ServiceFailure.accountDisabled }
        guard !quarantinedForSubscription else { throw ServiceFailure.accountCleanupPending }
        guard requests.count + binaryRequests.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let epoch = currentEpoch
        let work = Task { try dispatchBinary(request, body: body, context: context, epoch: epoch) }
        binaryRequests[id] = work
        defer { binaryRequests[id] = nil }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func dispatchBinary(
        _ request: ServiceRequest, body: Data, context: ServiceSessionContext, epoch: UUID
    ) throws -> ServiceBinaryFrame {
        try checkEpoch(epoch)
        if let deadline = request.header.deadline,
           deadline <= Date() {
            throw ServiceFailure.deadlineExceeded
        }
        try request.validateBinaryBody(body)
        let receipt: TransferChunkReceipt
        let bytes: Data
        switch request.operation {
        case WriteTransferChunk.operation:
            receipt = try writeUpload(
                request.decodePayload(WriteTransferChunk.self),
                body: body,
                context: context
            )
            bytes = Data()
        case ReadTransferChunk.operation:
            (receipt, bytes) = try readDownload(
                request.decodePayload(ReadTransferChunk.self),
                context: context
            )
        default: throw ServiceFailure.unsupportedOperation
        }
        return try ServiceBinaryFrame(
            header: ServiceCodec.encode(ServiceResponse(
                replyingTo: request,
                result: .success(ServiceCodec.value(receipt))
            )),
            body: bytes
        )
    }
}
