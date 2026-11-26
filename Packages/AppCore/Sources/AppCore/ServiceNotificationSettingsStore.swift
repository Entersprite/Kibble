import ChatKit
import ServiceClient

/// Presentation uses the durable client replica, never the service registry.
public struct ServiceNotificationSettingsStore: NotificationSettingsStore {
    private let cache: PolicyReplicaCache
    public init(cache: PolicyReplicaCache) {
        self.cache = cache
    }

    public func load(for account: Member.ID) throws -> NotificationSettings? {
        guard account == cache.binding.identity else { return nil }
        return cache.snapshot.settings
    }

    public func save(_ settings: NotificationSettings, for account: Member.ID) throws {
        guard account == cache.binding.identity else { throw PolicyIdentityMismatch() }
        try cache.save(settings)
    }

    public func deviceID() -> String {
        cache.deviceID
    }
}

private struct PolicyIdentityMismatch: Error {}
