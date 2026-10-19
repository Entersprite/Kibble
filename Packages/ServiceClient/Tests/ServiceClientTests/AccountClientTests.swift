import ChatAPI
import InProcessChatTransport
import ServiceClient
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AccountClientTests {
    @Test func twoClientAccountWatchersDetachIndependentlyAndTrackInactiveAccounts() async throws {
        let harness = try await ClientHarness.make()
        let client = AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let other = AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let firstLog = AccountLog()
        let secondLog = AccountLog()
        let firstStream = try await client.states()
        let secondStream = try await other.states()
        let first = Task { for try await state in firstStream {
            await firstLog.append(state)
        } }
        let second = Task { for try await state in secondStream {
            await secondLog.append(state)
        } }
        try await eventually {
            let first = await firstLog.latest
            let second = await secondLog.latest
            return first?.accounts.count == 2 && second?.accounts.count == 2
        }
        first.cancel()
        _ = await first.result
        _ = try await other.setEnabled(false, account: harness.second.id)
        try await eventually {
            await secondLog.latest?.accounts.first { $0.id == harness.second.id }?.isEnabled == false
        }
        #expect(await harness.service.activeRuntimeCount == 1)
        try await other.remove(harness.second.id)
        try await eventually { await secondLog.latest?.accounts.map(\.id) == [harness.first.id] }
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
        try await second.value
    }
}

private actor AccountLog {
    private(set) var latest: AccountStateSnapshot?
    func append(_ state: AccountStateSnapshot) {
        latest = state
    }
}
