import ChatAPI
import Foundation

/// Serialized request/response transport for an embedded service. The host binds
/// a trusted context; request payloads cannot replace that context.
public actor InProcessChatTransport: ServiceEventTransport {
    private let endpoint: any ServiceEndpoint
    private let context: ServiceSessionContext
    private let supportedVersion: ServiceAPIVersion
    private let maximumFrameBytes: Int
    private let maximumInFlight: Int
    private let now: @Sendable () -> Date
    private var version: ServiceAPIVersion?
    private var subscriptions: Set<UUID> = []
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
        if let account = request.header.accountID, !context.allowsAccount(account) {
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
              response.accountRevision == request.header.accountRevision,
              response.version == version
        else { throw ServiceFailure.invalidResponse }
        return response
    }

    public func events(_ request: ServiceRequest) async throws
        -> AsyncThrowingStream<ServiceEventPage, any Error> {
        try Task.checkCancellation()
        guard let version, request.header.version == version else { throw ServiceFailure.handshakeRequired }
        guard let account = request.header.accountID, context.allowsAccount(account) else {
            throw ServiceFailure.notAuthorized
        }
        _ = try request.decodePayload(ReadEvents.self)
        guard subscriptions.count + pending.count < maximumInFlight else { throw ServiceFailure.overloaded }
        let data = try ServiceCodec.encode(request)
        try checkSize(data)
        guard let endpoint = endpoint as? any ServiceEventEndpoint
        else { throw ServiceFailure.unsupportedOperation }
        let id = UUID()
        subscriptions.insert(id)
        do {
            let upstream = try await endpoint.events(data, context: context)
            let (stream, continuation) = AsyncThrowingStream<ServiceEventPage, any Error>.makeStream(
                bufferingPolicy: .bufferingOldest(1)
            )
            let task = Task { [weak self] in
                await self?.forward(upstream, account: account, id: id, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        } catch {
            subscriptions.remove(id)
            throw error
        }
    }

    private func forward(
        _ upstream: AsyncThrowingStream<Data, any Error>, account: ConnectedAccountID,
        id: UUID, into continuation: AsyncThrowingStream<ServiceEventPage, any Error>.Continuation
    ) async {
        do {
            for try await frame in upstream {
                try Task.checkCancellation()
                try checkSize(frame)
                let page = try ServiceCodec.decode(ServiceEventPage.self, from: frame)
                guard page.checkpoint.accountID == account,
                      page.events.allSatisfy({ $0.cursor.accountID == account }) else {
                    throw ServiceFailure.invalidResponse
                }
                if case .dropped = continuation.yield(page) {
                    throw ServiceFailure.overloaded
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error as? ServiceFailure ?? ServiceFailure.invalidResponse)
        }
        subscriptions.remove(id)
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
