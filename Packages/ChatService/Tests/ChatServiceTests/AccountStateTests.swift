import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AccountStateTests {
    private func request() throws -> ServiceRequest {
        try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID(UUID().uuidString)),
            payload: WatchAccounts()
        )
    }

    @Test func subscriptionLimitAndCancellationAreIndependentOfAccountLifetime() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record], maximumAccountSubscriptions: 2)
        let bytes = try ServiceCodec.encode(request())
        let firstStream = try await harness.service.accountStates(bytes, context: harness.context)
        let secondStream = try await harness.service.accountStates(bytes, context: harness.context)
        await #expect(throws: ServiceFailure.overloaded) {
            try await harness.service.accountStates(bytes, context: harness.context)
        }
        let consumer = Task { for try await _ in firstStream {} }
        consumer.cancel()
        _ = await consumer.result
        try await authEventually { await harness.service.accountSubscribers.count == 1 }
        #expect(await harness.service.activeRuntimeCount == 1)
        let thirdStream = try await harness.service.accountStates(bytes, context: harness.context)
        var secondIterator = secondStream.makeAsyncIterator()
        #expect(try await secondIterator.next() != nil)
        await harness.service.shutdown()
        var thirdIterator = thirdStream.makeAsyncIterator()
        _ = try await thirdIterator.next()
        #expect(try await thirdIterator.next() == nil)
    }

    @Test func initialAndReplacementSnapshotsContainOnlyGrantedPrincipalState() async throws {
        let harness = try await AuthHarness.make()
        let context = ServiceSessionContext(
            principalID: harness.context.principalID, deviceID: harness.context.deviceID,
            sessionID: ClientSessionID("limited"), accounts: [harness.first.id]
        )
        let stream = try await harness.service.accountStates(ServiceCodec.encode(request()), context: context)
        var iterator = stream.makeAsyncIterator()
        let initial = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await iterator.next())
        )
        #expect(initial.accounts.map(\.id) == [harness.first.id])
        #expect(initial.pendingLinks.isEmpty)
        _ = try await harness.call(SetAccountEnabled(enabled: false), account: harness.first.id)
        let changed = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await iterator.next())
        )
        #expect(changed.accounts.map(\.id) == [harness.first.id])
        #expect(changed.accounts.first?.isEnabled == false)
        #expect(try await harness.call(ListAccounts())
            .contains { $0.id == harness.second.id && $0.isEnabled })
        let foreign = ServiceSessionContext(
            principalID: ServicePrincipalID("other"), deviceID: context.deviceID,
            sessionID: ClientSessionID("foreign"), accounts: [], hasAllAccountAccess: true
        )
        let foreignStream = try await harness.service.accountStates(
            ServiceCodec.encode(request()), context: foreign
        )
        var foreignIterator = foreignStream.makeAsyncIterator()
        let hidden = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await foreignIterator.next())
        )
        #expect(hidden.accounts.isEmpty)
        await harness.service.shutdown()
    }

    @Test func pendingCaptureCanBeRediscoveredOnlyByItsLinkingDevice() async throws {
        let harness = try await LinkHarness.make()
        let stream = try await harness.service.accountStates(
            ServiceCodec.encode(request()), context: harness.context
        )
        var iterator = stream.makeAsyncIterator()
        let initial = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await iterator.next())
        )
        #expect(initial.accounts.isEmpty)
        #expect(initial.pendingLinks.isEmpty)
        let link = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("add")))
        #expect(try await harness.call(ListAccountLinks()) == [link])
        let pending = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await iterator.next())
        )
        #expect(pending.pendingLinks == [link])
        let foreignDevice = ServiceSessionContext(
            principalID: harness.context.principalID, deviceID: ServiceDeviceID("other"),
            sessionID: ClientSessionID("other"), accounts: [], hasAllAccountAccess: true,
            canLinkAccounts: true
        )
        let foreign = try await harness.service.accountStates(
            ServiceCodec.encode(request()),
            context: foreignDevice
        )
        var foreignIterator = foreign.makeAsyncIterator()
        let hidden = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await foreignIterator.next())
        )
        #expect(hidden.pendingLinks.isEmpty)
        _ = try await harness.call(CancelAccountLink(linkID: link.id))
        let canceled = try ServiceCodec.decode(
            AccountStateSnapshot.self,
            from: #require(await iterator.next())
        )
        #expect(canceled.pendingLinks.isEmpty)
        await harness.service.shutdown()
    }

    @Test func aPausedSubscriberRetainsOnlyTheLatestCompleteSnapshot() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let stream = try await harness.service.accountStates(
            ServiceCodec.encode(request()), context: harness.context
        )
        for index in 0 ..< 20 {
            _ = try await harness.call(SetAccountEnabled(enabled: index % 2 == 0), account: record.id)
        }
        _ = try await harness.call(RemoveAccount(), account: record.id)
        var iterator = stream.makeAsyncIterator()
        let latest = try ServiceCodec.decode(AccountStateSnapshot.self, from: #require(await iterator.next()))
        #expect(latest.accounts.isEmpty)
        #expect(latest.pendingLinks.isEmpty)
        await harness.service.shutdown()
        #expect(try await iterator.next() == nil)
    }

    @Test func fatalAuthenticationIsVisibleWithoutAnyChatSubscriber() async throws {
        let harness = try await AuthHarness.make()
        let backend = try await harness.backend(harness.first.id)
        let stream = try await harness.service.accountStates(
            ServiceCodec.encode(request()), context: harness.context
        )
        let log = StateLog()
        let task = Task { for try await data in stream {
            try await log.append(ServiceCodec.decode(AccountStateSnapshot.self, from: data))
        } }
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually {
            await log.latest?.accounts.first { $0.id == harness.first.id }?.authenticationState == "required"
        }
        let latest = try #require(await log.latest)
        #expect(latest.accounts.first { $0.id == harness.second.id }?.authenticationState == nil)
        #expect(latest.accounts.first { $0.id == harness.first.id }?.revision == harness.first
            .currentRevision)
        await harness.service.shutdown()
        try await task.value
    }
}

private actor StateLog {
    private(set) var latest: AccountStateSnapshot?
    func append(_ state: AccountStateSnapshot) {
        latest = state
    }
}
