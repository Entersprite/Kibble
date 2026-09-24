import ChatKit
import Foundation
import Synchronization

/// Where one account's notification settings are kept. `MacHost` supplies the
/// JSON file store; tests and any host without files use the in-memory one.
/// A future synced store is one more conformance (spec §6).
public protocol NotificationSettingsStore: Sendable {
    func load(for account: Member.ID) throws -> NotificationSettings?
    func save(_ settings: NotificationSettings, for account: Member.ID) throws
    /// This install's id - the `modifiedBy` on every record it writes. Never synced.
    func deviceID() throws -> String
}

public final class InMemoryNotificationSettingsStore: NotificationSettingsStore {
    private let state: Mutex<[Member.ID: NotificationSettings]>
    private let device: String

    public init(_ initial: [Member.ID: NotificationSettings] = [:], deviceID: String = "in-memory-device") {
        state = Mutex(initial)
        device = deviceID
    }

    public func load(for account: Member.ID) -> NotificationSettings? {
        state.withLock { $0[account] }
    }

    public func save(_ settings: NotificationSettings, for account: Member.ID) {
        state.withLock { $0[account] = settings }
    }

    public func deviceID() -> String {
        device
    }

    /// What was last saved for `account` - for tests.
    public func saved(for account: Member.ID) -> NotificationSettings? {
        load(for: account)
    }
}
