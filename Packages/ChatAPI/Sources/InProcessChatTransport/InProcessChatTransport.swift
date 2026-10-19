import ChatAPI
import Foundation

/// Serialized request/response transport for an embedded service. The host binds
/// a trusted context; request payloads cannot replace that context.
public actor InProcessChatTransport: ServiceTransport {
    private let endpoint: any ServiceEndpoint
    private let context: ServiceSessionContext
    private let supportedVersion: ServiceAPIVersion
    private let maximumFrameBytes: Int
    private let maximumInFlight: Int
    private let now: @Sendable () -> Date
    private var version: ServiceAPIVersion?
    private var pending: [ServiceRequestID: RequestCompletion] = [:]

    public init(
        endpoint: any ServiceEndpoint,
        context: ServiceSessionContext,
        supportedVersion: ServiceAPIVersion = .current,
        maximumFrameBytes: Int = 4 * 1024 * 1024,
        maximumInFlight: Int = 64,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.context = context
        self.supportedVersion = supportedVersion
        self.maximumFrameBytes = max(0, maximumFrameBytes)
        self.maximumInFlight = max(0, maximumInFlight)
        self.now = now
    }

    public func negotiate(_ peer: ServiceAPIVersion) throws -> ServiceAPIVersion {
        let agreed = try supportedVersion.negotiated(with: peer)
        if let version, version != agreed {
            throw ServiceFailure.incompatibleVersion
        }
        version = agreed
        return agreed
    }

    public func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        try Task.checkCancellation()
        guard let version else { throw ServiceFailure.handshakeRequired }
        guard request.header.version == version else { throw ServiceFailure.incompatibleVersion }
        if let account = request.header.accountID, !context.accounts.contains(account) {
            throw ServiceFailure.notAuthorized
        }
        let data = try ServiceCodec.encode(request)
        try checkSize(data)
        let deadline = try remainingTime(for: request)
        guard pending[request.header.requestID] == nil else { throw ServiceFailure.duplicateRequest }
        guard pending.count < maximumInFlight else { throw ServiceFailure.overloaded }
        let completion = RequestCompletion()
        pending[request.header.requestID] = completion
        let endpoint = endpoint
        let context = context
        let responseData = try await completion.run(deadline: deadline, operation: {
            try await endpoint.handle(data, context: context)
        }, finished: { [weak self] in
            await self?.finished(request.header.requestID)
        })
        try Task.checkCancellation()
        _ = try remainingTime(for: request)
        try checkSize(responseData)
        let response: ServiceResponse
        do {
            response = try ServiceCodec.decode(ServiceResponse.self, from: responseData)
        } catch {
            throw ServiceFailure.invalidResponse
        }
        guard response.requestID == request.header.requestID,
              response.accountID == request.header.accountID,
              response.version == version
        else { throw ServiceFailure.invalidResponse }
        return response
    }

    private func remainingTime(for request: ServiceRequest) throws -> Duration? {
        guard let deadline = request.header.deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining.isFinite, remaining > 0 else { throw ServiceFailure.deadlineExceeded }
        return .seconds(remaining)
    }

    private func checkSize(_ data: Data) throws {
        guard data.count <= maximumFrameBytes else { throw ServiceFailure.frameTooLarge }
    }

    private func finished(_ requestID: ServiceRequestID) {
        pending[requestID] = nil
    }
}
