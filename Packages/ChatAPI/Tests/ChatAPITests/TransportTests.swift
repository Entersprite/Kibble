import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Testing

@Suite("Embedded service transport", .timeLimit(.minutes(1)))
struct TransportTests {
    @Test
    func embeddedCallsUseSerializedValuesAndTrustedContext() async throws {
        let endpoint = Endpoint()
        let trusted = context()
        let transport = InProcessChatTransport(endpoint: endpoint, context: trusted)
        _ = try await transport.negotiate(.current)
        let response = try await transport.exchange(request())
        let accounts = try response.value(for: ListAccounts.self)
        #expect(accounts.map(\.id) == [accountA])
        let contexts = await endpoint.contexts
        #expect(contexts == [trusted])
    }

    @Test
    func twoAccountsCanKeepTheSameConversationIdentity() async throws {
        let endpoint = Endpoint()
        let transport = InProcessChatTransport(
            endpoint: endpoint,
            context: context(accounts: [accountA, accountB])
        )
        _ = try await transport.negotiate(.current)
        let first = try await transport.exchange(request(id: "one", account: accountA))
        let second = try await transport.exchange(request(id: "two", account: accountB))
        #expect(first.accountID == accountA)
        #expect(second.accountID == accountB)
        let firstRows = try first.value(for: LoadConversations.self)
        let secondRows = try second.value(for: LoadConversations.self)
        #expect(firstRows.first?.id == secondRows.first?.id)
        #expect(!firstRows.isEmpty)
    }

    @Test
    func ungrantedAccountsNeverReachTheEndpoint() async throws {
        let endpoint = Endpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await transport.exchange(request(account: accountB))
        }
        let received = await endpoint.requests
        #expect(received.isEmpty)
    }

    @Test
    func handshakeAndRequestVersionAreEnforced() async throws {
        let endpoint = Endpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        await #expect(throws: ServiceFailure.handshakeRequired) { try await transport.exchange(request()) }
        _ = try await transport.negotiate(.current)
        let foreign = try ServiceRequest(
            header: .init(requestID: ServiceRequestID("version"), version: .init(major: 2, minor: 0)),
            payload: ListAccounts()
        )
        await #expect(throws: ServiceFailure.incompatibleVersion) { try await transport.exchange(foreign) }
        let received = await endpoint.requests
        #expect(received.isEmpty)
    }

    @Test(arguments: [Endpoint.Mode.wrongRequest, .wrongAccount, .wrongVersion])
    func foreignResponsesAreRejected(_ mode: Endpoint.Mode) async throws {
        let transport = InProcessChatTransport(endpoint: Endpoint(mode), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.invalidResponse) { try await transport.exchange(request()) }
    }

    @Test
    func hostErrorsAreConvertedToSafeFailures() async throws {
        let transport = InProcessChatTransport(endpoint: Endpoint(.hostFailure), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.internalFailure) { try await transport.exchange(request()) }
    }

    @Test
    func malformedResponsesAreSafeFailures() async throws {
        let transport = InProcessChatTransport(endpoint: Endpoint(.malformed), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.invalidResponse) { try await transport.exchange(request()) }
    }

    @Test
    func requestPayloadCannotReplaceTheAuthenticatedContext() async throws {
        let endpoint = Endpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let forged = ServiceRequest(
            header: .init(requestID: ServiceRequestID("forged")), operation: ListAccounts.operation,
            payload: .object([
                "principalID": .string("attacker"), "accounts": .array([.string(accountB.rawValue)])
            ])
        )
        let response = try await transport.exchange(forged)
        #expect(try response.value(for: ListAccounts.self).map(\.id) == [accountA])
        let received = await endpoint.contexts
        #expect(received == [context()])
    }

    @Test
    func aRawRequestStillNeedsItsOperationsAccountScope() async throws {
        let transport = InProcessChatTransport(endpoint: Endpoint(), context: context())
        _ = try await transport.negotiate(.current)
        let forged = ServiceRequest(
            header: .init(requestID: ServiceRequestID("missing")),
            operation: LoadConversations.operation, payload: .object([:])
        )
        await #expect(throws: ServiceFailure.accountRequired) { try await transport.exchange(forged) }
    }

    @Test
    func outstandingRequestIDsCannotBeReused() async throws {
        let endpoint = Endpoint(.held)
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let safety = Task { try? await Task.sleep(for: .seconds(2)); await endpoint.release() }
        defer { safety.cancel() }
        let first = Task { try await transport.exchange(request()) }
        await endpoint.waitForRequest()
        await #expect(throws: ServiceFailure.duplicateRequest) { try await transport.exchange(request()) }
        await endpoint.release()
        _ = try await first.value
        let received = await endpoint.requests
        #expect(received.count == 1)
    }

    @Test
    func expiredRequestsNeverReachTheEndpoint() async throws {
        let endpoint = Endpoint()
        let now = Date(timeIntervalSince1970: 100)
        let transport = InProcessChatTransport(endpoint: endpoint, context: context(), now: { now })
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.deadlineExceeded) {
            try await transport.exchange(request(deadline: now))
        }
        let received = await endpoint.requests
        #expect(received.isEmpty)
    }

    @Test
    func requestAndResponseFramesAreBounded() async throws {
        let endpoint = Endpoint()
        let requestBound = InProcessChatTransport(
            endpoint: endpoint,
            context: context(),
            maximumFrameBytes: 1
        )
        _ = try await requestBound.negotiate(.current)
        await #expect(throws: ServiceFailure.frameTooLarge) { try await requestBound.exchange(request()) }
        let received = await endpoint.requests
        #expect(received.isEmpty)
        let responseBound = InProcessChatTransport(
            endpoint: Endpoint(.large), context: context(), maximumFrameBytes: 1024
        )
        _ = try await responseBound.negotiate(.current)
        await #expect(throws: ServiceFailure.frameTooLarge) { try await responseBound.exchange(request()) }
    }

    @Test
    func timedOutUncooperativeWorkStillConsumesItsSlot() async throws {
        let endpoint = Endpoint(.held)
        let now = Date(timeIntervalSince1970: 100)
        let transport = InProcessChatTransport(
            endpoint: endpoint, context: context(), maximumInFlight: 1, now: { now }
        )
        _ = try await transport.negotiate(.current)
        // Bounds the test even if deadline delivery regresses.
        let safety = Task { try? await Task.sleep(for: .seconds(2)); await endpoint.release() }
        defer { safety.cancel() }
        let first = Task { try await transport.exchange(request(deadline: now.addingTimeInterval(0.02))) }
        await endpoint.waitForRequest()
        await #expect(throws: ServiceFailure.deadlineExceeded) { try await first.value }
        await #expect(throws: ServiceFailure.overloaded) {
            try await transport.exchange(request(id: "second"))
        }
        await endpoint.release()
    }

    @Test
    func callerCancellationDoesNotWaitForTheEndpoint() async throws {
        let endpoint = Endpoint(.held)
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let safety = Task { try? await Task.sleep(for: .seconds(2)); await endpoint.release() }
        defer { safety.cancel() }
        let task = Task { try await transport.exchange(request()) }
        await endpoint.waitForRequest()
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        await endpoint.release()
    }
}
