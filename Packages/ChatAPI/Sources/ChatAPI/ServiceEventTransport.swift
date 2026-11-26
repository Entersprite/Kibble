import Foundation

/// Host endpoint for a stream of serialized, independently checkpointed pages.
/// A canceled subscription releases only that client interest.
public protocol ServiceEventEndpoint: ServiceEndpoint {
    func events(_ request: Data, context: ServiceSessionContext) async throws
        -> AsyncThrowingStream<Data, any Error>
}

public protocol ServiceEventTransport: ServiceTransport {
    func events(_ request: ServiceRequest) async throws -> AsyncThrowingStream<ServiceEventPage, any Error>
}
