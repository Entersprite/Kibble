import ChatAPI
import Foundation
import InProcessChatTransport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DurableStreamOverflowTests {
    @Test func aFullEventQueueRequestsReplayRatherThanReportingAdmissionOverload() async throws {
        let endpoint = BurstEventEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context(), maximumInFlight: 1)
        _ = try await transport.negotiate(.current)
        let stream = try await transport.events(ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID("events"), accountID: accountA
        ), payload: ReadEvents(cursor: nil, limit: 10)))
        try await endpoint.burst()
        // Waiting for the slot proves forwarding has finished while the consumer is paused.
        try await waitForSlot(transport)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        await #expect(throws: ServiceFailure.resynchronizationRequired) { try await iterator.next() }
    }

    private func waitForSlot(_ transport: InProcessChatTransport) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            do {
                _ = try await transport.exchange(request(id: UUID().uuidString))
                return
            } catch let failure as ServiceFailure where failure == .overloaded {
                await Task.yield()
            }
        }
        throw ServiceFailure.deadlineExceeded
    }
}

private actor BurstEventEndpoint: ServiceEventEndpoint {
    private var sink: AsyncThrowingStream<Data, any Error>.Continuation?

    func handle(_ data: Data, context: ServiceSessionContext) throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: data)
        return try ServiceCodec.encode(ServiceResponse(replyingTo: request, result: .success(.array([]))))
    }

    func events(_ data: Data, context: ServiceSessionContext) -> AsyncThrowingStream<Data, any Error> {
        let (stream, sink) = AsyncThrowingStream<Data, any Error>
            .makeStream(bufferingPolicy: .bufferingOldest(8))
        self.sink = sink
        return stream
    }

    func burst() throws {
        for sequence in 1 ... 3 {
            try sink?.yield(ServiceCodec.encode(ServiceEventPage(checkpoint: ServiceCursor(
                accountID: accountA, streamID: ServiceStreamID("stream"), sequence: UInt64(sequence)
            ), snapshot: nil, events: [], hasMore: false)))
        }
        sink?.finish()
    }
}
