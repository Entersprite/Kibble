import ChatAPI
import ChatKit
import ChatService
import FixtureBackend
import Foundation

actor FixtureAccountProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: WeakFixtureBackend] = [:]
    var retainedCount: Int {
        backends.values.filter { $0.backend != nil }.count
    }

    func makeProvider(for account: AccountRecord) async -> AccountProvider {
        var world = FixtureWorld.acme
        world.me = account.selfID
        if !world.members.contains(where: { $0.id == account.selfID }) {
            world.members.append(Member(id: account.selfID, kind: .human, displayName: account.label))
        }
        let backend = FakeBackend(
            world: world,
            directory: FixtureWorld.acmeDirectory,
            identifierNamespace: UUID().uuidString
        )
        backends[account.id] = WeakFixtureBackend(backend)
        let now = world.startedAt
        let calls = await FixtureAudioCallService(world: world)
        return AccountProvider(backend: backend, calls: [.init("fixture-device"): calls], now: { now })
    }

    func forgetCredentials(for account: AccountRecord) {
        backends[account.id] = nil
    }

    func incoming(_ account: ConnectedAccountID, text: String) async {
        try? await backends[account]?.backend?.apply(.incomingMessage(
            conversation: Acme.priceEngine, from: Acme.dan, text: text, thread: nil
        ))
    }
}

private final class WeakFixtureBackend {
    weak var backend: FakeBackend?
    init(_ backend: FakeBackend) {
        self.backend = backend
    }
}
