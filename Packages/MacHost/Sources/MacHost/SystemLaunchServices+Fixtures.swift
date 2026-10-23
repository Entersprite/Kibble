import AppCore
import ChatAPI
import ChatKit
import ChatService
import FixtureBackend
import Foundation

extension SystemLaunchServices {
    /// `--backend=fixture`: the demo world, with its call going on in
    /// storefront-web for Join to find.
    func makeFixtureSession() async -> SessionSelection {
        let fixture = FakeBackend(world: .acmeDemo, directory: FixtureWorld.acmeDirectory)
        // The demo world's dates are literals (2026-08-31), so the mention
        // backfill's window is anchored at the world's own start rather
        // than the wall clock, which would leave it empty.
        let demoNow = FixtureWorld.acme.startedAt
        let calls = FixtureAudioCallService()
        await Acme.scriptStorefrontCall(backend: fixture, calls: calls)
        return SessionSelection(
            backend: fixture,
            me: Acme.alex,
            driver: FixtureDemoDriver(backend: fixture),
            audioCalls: calls,
            now: { demoNow }
        )
    }
}

actor FixtureAccountProviders: AccountProviderFactory {
    private var backends: [ConnectedAccountID: WeakFixtureBackend] = [:]
    var retainedCount: Int {
        backends.values.filter { $0.backend != nil }.count
    }

    func makeProvider(for account: AccountRecord) async -> AccountProvider {
        var world = FixtureWorld.acmeDemo
        world.me = account.selfID
        if !world.members.contains(where: { $0.id == account.selfID }) {
            let handle = account.label.lowercased().replacingOccurrences(of: " ", with: "-")
            world.members.append(Member(
                id: account.selfID, kind: .human, displayName: account.label,
                email: "\(handle)@example.invalid"
            ))
        }
        let backend = FakeBackend(
            world: world,
            directory: FixtureWorld.acmeDirectory,
            identifierNamespace: UUID().uuidString,
            organization: Self.organization(for: account)
        )
        backends[account.id] = WeakFixtureBackend(backend)
        let now = world.startedAt
        let calls = await FixtureAudioCallService(world: world)
        await Acme.scriptStorefrontCall(backend: backend, calls: calls)
        return AccountProvider(backend: backend, calls: [.init("fixture-device"): calls], now: { now })
    }

    /// Every way an account can be labeled: the studio demo is managed, the
    /// personal demo is not, and added demo accounts alternate, so a second
    /// personal account exercises the label collision.
    private static func organization(for account: AccountRecord) -> AccountOrganization {
        switch account.id.rawValue {
        case "personal": return .personal
        case "studio": return .managed(domain: "studio.test")
        default:
            let number = Int(account.label.split(separator: " ").last ?? "") ?? 0
            switch number % 3 {
            case 0: return .managed(domain: "acme.test")
            case 1: return .personal
            default: return .unstated
            }
        }
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
