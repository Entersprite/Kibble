import ChatAPI
import Foundation

extension ChatService: ServiceBinaryEndpoint {
    public func binary(
        _ header: Data, body: Data, context: ServiceSessionContext
    ) async throws -> ServiceBinaryFrame {
        guard header.count <= ServiceBinaryLimits.maximumHeaderBytes,
              body.count <= ServiceBinaryLimits.maximumChunkBytes else { throw ServiceFailure.frameTooLarge }
        let request = try ServiceCodec.decode(ServiceRequest.self, from: header)
        do {
            _ = try ServiceAPIVersion.current.negotiated(with: request.header.version)
            try request.validateBinaryBody(body)
            guard restoredForSubscriptions, !shuttingDown else { throw ServiceFailure.overloaded }
            if let deadline = request.header.deadline,
               deadline <= Date() {
                throw ServiceFailure.deadlineExceeded
            }
            guard let id = request.header.accountID, context.allowsAccount(id),
                  let record = records[id], record.principalID == context.principalID else {
                throw ServiceFailure.notAuthorized
            }
            guard request.header.accountRevision == record.currentRevision
            else { throw ServiceFailure.staleAccount }
            try checkAuthentication(record)
            guard record.isEnabled, !record.isRemoving, !changing.contains(id) else {
                throw ServiceFailure.accountDisabled
            }
            guard let runtime = runtimes[id] else { throw ServiceFailure.overloaded }
            return try await runtime.handleBinary(request, body: body, context: context)
        } catch {
            return try ServiceBinaryFrame(
                header: ServiceCodec.encode(ServiceResponse(
                    replyingTo: request,
                    result: .failure(serviceFailure(error))
                )),
                body: Data()
            )
        }
    }
}
