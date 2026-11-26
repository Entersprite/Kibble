import ChatAPI
import Foundation

/// Serialized request/response transport for an embedded service. The host binds
/// a trusted context; request payloads cannot replace that context.
public actor InProcessChatTransport: ServiceEventTransport, ServiceAccountStateTransport,
    ServiceBinaryTransport {
    private let endpoint: any ServiceEndpoint
    private let context: ServiceSessionContext
    private let supportedVersion: ServiceAPIVersion
    private let maximumFrameBytes: Int
    private let maximumInFlight: Int
    private let now: @Sendable () -> Date
    private var version: ServiceAPIVersion?
    private var pending: Set<ServiceRequestID> = []
    private var opening: Set<ServiceRequestID> = []
    private var abandoned: Set<ServiceRequestID> = []

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
        guard !pending.contains(request.header.requestID) else { throw ServiceFailure.duplicateRequest }
        guard pending.count < maximumInFlight else { throw ServiceFailure.overloaded }
        let completion = RequestCompletion<Data>()
        pending.insert(request.header.requestID)
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

    public func exchangeBinary(_ request: ServiceRequest, body: Data) async throws -> ServiceBinaryReply {
        try Task.checkCancellation()
        guard let version else { throw ServiceFailure.handshakeRequired }
        guard request.header.version == version else { throw ServiceFailure.incompatibleVersion }
        guard let account = request.header.accountID, context.allowsAccount(account) else {
            throw ServiceFailure.notAuthorized
        }
        try request.validateBinaryBody(body)
        guard let endpoint = endpoint as? any ServiceBinaryEndpoint else {
            throw ServiceFailure.unsupportedOperation
        }
        let header = try ServiceCodec.encode(request)
        guard header.count <= ServiceBinaryLimits.maximumHeaderBytes else {
            throw ServiceFailure.frameTooLarge
        }
        try checkSize(header)
        let deadline = try remainingTime(for: request)
        let id = request.header.requestID
        guard !pending.contains(id) else { throw ServiceFailure.duplicateRequest }
        guard pending.count < maximumInFlight else { throw ServiceFailure.overloaded }
        pending.insert(id)
        let frame = try await RequestCompletion<ServiceBinaryFrame>().run(
            deadline: deadline,
            operation: { [context] in try await endpoint.binary(header, body: body, context: context) },
            finished: { [weak self] in await self?.finished(id) }
        )
        try Task.checkCancellation()
        _ = try remainingTime(for: request)
        return try decodeBinary(frame, for: request, version: version)
    }

    private func decodeBinary(
        _ frame: ServiceBinaryFrame, for request: ServiceRequest, version: ServiceAPIVersion
    ) throws -> ServiceBinaryReply {
        guard frame.header.count <= ServiceBinaryLimits.maximumHeaderBytes,
              frame.body.count <= ServiceBinaryLimits.maximumChunkBytes else {
            throw ServiceFailure.frameTooLarge
        }
        try checkSize(frame.header)
        let response: ServiceResponse
        do {
            response = try ServiceCodec.decode(ServiceResponse.self, from: frame.header)
        } catch {
            throw ServiceFailure.invalidResponse
        }
        guard response.requestID == request.header.requestID, response.accountID == request.header.accountID,
              response.accountRevision == request.header.accountRevision, response.version == version else {
            throw ServiceFailure.invalidResponse
        }
        let reply = ServiceBinaryReply(response: response, body: frame.body)
        do {
            try reply.validateChunk(for: request)
        } catch {
            throw ServiceFailure.invalidResponse
        }
        return reply
    }

    public func events(_ request: ServiceRequest) async throws
        -> AsyncThrowingStream<ServiceEventPage, any Error> {
        guard let account = request.header.accountID, context.allowsAccount(account) else {
            throw ServiceFailure.notAuthorized
        }
        _ = try request.decodePayload(ReadEvents.self)
        guard let endpoint = endpoint as? any ServiceEventEndpoint
        else { throw ServiceFailure.unsupportedOperation }
        return try await stream(request, replacingSnapshots: false, open: { [context] data in
            try await endpoint.events(data, context: context)
        }, decode: { frame in
            let page = try ServiceCodec.decode(ServiceEventPage.self, from: frame)
            guard page.checkpoint.accountID == account,
                  page.events.allSatisfy({ $0.cursor.accountID == account }) else {
                throw ServiceFailure.invalidResponse
            }
            return page
        })
    }

    public func accountStates(_ request: ServiceRequest) async throws
        -> AsyncThrowingStream<AccountStateSnapshot, any Error> {
        _ = try request.decodePayload(WatchAccounts.self)
        guard let endpoint = endpoint as? any ServiceAccountStateEndpoint
        else { throw ServiceFailure.unsupportedOperation }
        return try await stream(request, replacingSnapshots: true, open: { [context] data in
            try await endpoint.accountStates(data, context: context)
        }, decode: { [context] frame in
            let snapshot = try ServiceCodec.decode(AccountStateSnapshot.self, from: frame)
            guard snapshot.accounts.allSatisfy({ context.allowsAccount($0.id) }),
                  context.canLinkAccounts || snapshot.pendingLinks.isEmpty else {
                throw ServiceFailure.invalidResponse
            }
            return snapshot
        })
    }

    private func stream<Value: Sendable>(
        _ request: ServiceRequest, replacingSnapshots: Bool,
        open: @escaping @Sendable (Data) async throws -> AsyncThrowingStream<Data, any Error>,
        decode: @escaping @Sendable (Data) throws -> Value
    ) async throws -> AsyncThrowingStream<Value, any Error> {
        try Task.checkCancellation()
        guard let version else { throw ServiceFailure.handshakeRequired }
        guard request.header.version == version else { throw ServiceFailure.incompatibleVersion }
        let data = try ServiceCodec.encode(request)
        try checkSize(data)
        let deadline = try remainingTime(for: request)
        let id = request.header.requestID
        guard !pending.contains(id) else { throw ServiceFailure.duplicateRequest }
        guard pending.count < maximumInFlight else { throw ServiceFailure.overloaded }
        pending.insert(id)
        opening.insert(id)
        do {
            let upstream = try await RequestCompletion<AsyncThrowingStream<Data, any Error>>().run(
                deadline: deadline, operation: { try await open(data) },
                discard: { await Self.cancelStream($0) },
                finished: { [weak self] in await self?.opened(id) }
            )
            do {
                try Task.checkCancellation()
                _ = try remainingTime(for: request)
            } catch {
                await Self.cancelStream(upstream)
                throw error
            }
            let policy: AsyncThrowingStream<Value, any Error>.Continuation.BufferingPolicy =
                replacingSnapshots ? .bufferingNewest(1) : .bufferingOldest(1)
            let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(
                bufferingPolicy: policy
            )
            let task = Task { [weak self] in
                await self?.forward(
                    upstream, id: id, replacingSnapshots: replacingSnapshots,
                    decode: decode, into: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        } catch {
            if opening.contains(id) {
                abandoned.insert(id)
            } else {
                pending.remove(id)
            }
            throw error
        }
    }

    private func opened(_ id: ServiceRequestID) {
        opening.remove(id)
        if abandoned.remove(id) != nil {
            pending.remove(id)
        }
    }

    private nonisolated static func cancelStream(_ stream: AsyncThrowingStream<Data, any Error>) async {
        let task = Task {
            for try await _ in stream {
                try Task.checkCancellation()
            }
        }
        task.cancel()
        _ = await task.result
    }

    private func forward<Value: Sendable>(
        _ upstream: AsyncThrowingStream<Data, any Error>, id: ServiceRequestID,
        replacingSnapshots: Bool, decode: @Sendable (Data) throws -> Value,
        into continuation: AsyncThrowingStream<Value, any Error>.Continuation
    ) async {
        do {
            for try await frame in upstream {
                try Task.checkCancellation()
                try checkSize(frame)
                let value = try decode(frame)
                if case .dropped = continuation.yield(value), !replacingSnapshots {
                    throw ServiceFailure.resynchronizationRequired
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error as? ServiceFailure ?? ServiceFailure.invalidResponse)
        }
        pending.remove(id)
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
        pending.remove(requestID)
    }
}
