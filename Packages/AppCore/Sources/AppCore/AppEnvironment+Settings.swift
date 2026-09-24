import ChatKit
import Foundation
import Observation
import SyncEngine

extension AppEnvironment {
    /// Points the engine's receipts gate at the settings, now and on every
    /// change. `nil` settings - no account - withholds (spec §3.1).
    func beginSettingsSession(engine: SyncEngine) {
        let gate = engine.readReceipts
        receiptGate = gate
        let apply: @MainActor (NotificationSettings?) -> Void = { current in
            gate.set(current.map(ReadReceiptPolicy.resolve) ?? .withhold)
        }
        apply(settings.account == nil ? nil : settings.settings)
        settings.onChange = apply
    }

    /// Switches the settings to whoever the model says is signed in, the moment
    /// it says so - from the store on a returning launch, from
    /// `ChatEvent.selfIdentified` otherwise.
    func followIdentity(of model: ChatSessionModel) {
        identityTask?.cancel()
        identityTask = Task { [weak self] in
            for await me in Observations({ model.me }) {
                self?.settings.switchAccount(to: me)
            }
        }
    }
}

public extension AppEnvironment {
    /// The Dock and menu-bar count: unread conversations whose rule counts them.
    var badgeCount: Int {
        guard case let .running(model) = phase else { return 0 }
        return settings.settings.badgeCount(of: model.conversations)
    }
}
