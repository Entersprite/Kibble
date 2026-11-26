import AppCore
import ChatAPI
import ChatKit
import ChatService
import FixtureBackend
import Foundation

extension SystemLaunchServices {
    /// Screenshot demo with fictional studio conversations and bundled media.
    func makeFixtureSession() async -> SessionSelection {
        let fixture = FakeBackend(world: .showcase, directory: Showcase.directory)
        // Keep dated demo history and mention windows on the same fixed clock.
        let demoNow = FixtureWorld.showcase.startedAt
        return SessionSelection(
            backend: fixture,
            me: Showcase.alex,
            driver: FixtureDemoDriver(backend: fixture, script: .showcaseDemo, repeats: false),
            audioCalls: FixtureAudioCallService(world: .showcase),
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
