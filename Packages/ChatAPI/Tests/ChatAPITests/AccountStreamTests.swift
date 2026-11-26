import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AccountStreamTests {
    private func watch(deadline: Date? = nil) throws -> ServiceRequest {
        try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("watch"), deadline: deadline),
            payload: WatchAccounts()
        )
    }

    @Test func aSubscriptionAndOrdinaryRequestsShareOneWorkBudget() async throws {
        let endpoint = AccountStreamEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context(), maximumInFlight: 1)
        _ = try await transport.negotiate(.current)
        let stream = try await transport.accountStates(watch())
        await #expect(throws: ServiceFailure.overloaded) { try await transport.exchange(request()) }
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = await consumer.result
        try await waitForSlot(transport)
    }

    @Test(arguments: [true, false])
    func openingDeadlineAndCancellationDoNotWaitForUncooperativeEndpoints(deadline: Bool) async throws {
        let endpoint = AccountStreamEndpoint(held: true)
        let now = Date(timeIntervalSince1970: 100)
        let transport = InProcessChatTransport(
            endpoint: endpoint, context: context(), maximumInFlight: 1, now: { now }
        )
        _ = try await transport.negotiate(.current)
        let safety = Task { try? await Task.sleep(for: .seconds(2)); await endpoint.release() }
        defer { safety.cancel() }
        let task = Task {
            try await transport.accountStates(watch(deadline: deadline ? now.addingTimeInterval(0.02) : nil))
        }
        let openingDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < openingDeadline, await !endpoint.opened {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await endpoint.opened)
        let started = ContinuousClock.now
        if deadline {
            await #expect(throws: ServiceFailure.deadlineExceeded) { try await task.value }
        } else {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        await #expect(throws: ServiceFailure.overloaded) { try await transport.exchange(request()) }
        await endpoint.release()
        try await waitForSlot(transport)
        let cleanupDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < cleanupDeadline, await !endpoint.terminated {
            await Task.yield()
        }
        #expect(await endpoint.terminated)
    }

    @Test func pausedControlPlaneDeliveryReplacesSnapshotsAndPreservesTheLatest() async throws {
        let endpoint = AccountStreamEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context(), maximumInFlight: 1)
        _ = try await transport.negotiate(.current)
        let stream = try await transport.accountStates(watch())
        for index in 0 ..< 100 {
            try await endpoint.send(index: index)
        }
        await endpoint.finish()
        // Slot release proves that forwarding consumed the final upstream frame.
        try await waitForSlot(transport)
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.accounts.first?.label == "99")
        #expect(try await iterator.next() == nil)
    }

    @Test func forgedSnapshotAccountsAndOversizedFramesAreRefused() async throws {
        for foreign in [true, false] {
            let endpoint = AccountStreamEndpoint()
            let transport = InProcessChatTransport(
                endpoint: endpoint,
                context: context(),
                maximumFrameBytes: 1024
            )
            _ = try await transport.negotiate(.current)
            let stream = try await transport.accountStates(watch())
            if foreign {
                try await endpoint.send(index: 0, account: accountB)
            } else {
                await endpoint.sendRaw(Data(repeating: 32, count: 2048))
            }
            var iterator = stream.makeAsyncIterator()
            await #expect(throws: foreign ? ServiceFailure.invalidResponse : .frameTooLarge) {
                try await iterator.next()
            }
        }
    }

    private func waitForSlot(_ transport: InProcessChatTransport) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            do {
                _ = try await transport.exchange(request(id: UUID().uuidString))
                return
            } catch let error as ServiceFailure where error == .overloaded {
                await Task.yield()
            }
        }
        throw ServiceFailure.deadlineExceeded
    }
}

private actor AccountStreamEndpoint: ServiceAccountStateEndpoint {
    let held: Bool
    private(set) var opened = false
    private(set) var terminated = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var sink: AsyncThrowingStream<Data, any Error>.Continuation?
    private var retainedStream: AsyncThrowingStream<Data, any Error>?

    init(held: Bool = false) {
        self.held = held
    }

    func handle(_ bytes: Data, context: ServiceSessionContext) throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: bytes)
        return try ServiceCodec.encode(ServiceResponse(replyingTo: request, result: .success(.array([]))))
    }

    func accountStates(
        _ bytes: Data,
        context: ServiceSessionContext
    ) async -> AsyncThrowingStream<Data, any Error> {
        opened = true
        if held, !released {
            await withCheckedContinuation { waiter = $0 }
        }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in Task { await self?.didTerminate() } }
        sink = continuation
        retainedStream = stream
        return stream
    }

    func didTerminate() {
        terminated = true
        retainedStream = nil
    }

    func release() {
        released = true; waiter?.resume(); waiter = nil
    }

    func finish() {
        sink?.finish()
    }

    func sendRaw(_ data: Data) {
        sink?.yield(data)
    }

    func send(index: Int, account: ConnectedAccountID = accountA) throws {
        try sink?.yield(ServiceCodec.encode(AccountStateSnapshot(accounts: [AccountSummary(
            id: account, selfID: Member.ID("self"), label: String(index), connection: .connected
        )], pendingLinks: [])))
    }
}
