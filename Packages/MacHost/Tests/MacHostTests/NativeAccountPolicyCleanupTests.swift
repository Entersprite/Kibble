import AppCore
import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing
@testable import MacHost

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeAccountPolicyCleanupTests {
    @Test func resumedRemovalForgetsLocalPreferencesBeforeDroppingTheRecord() async throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        var record = AccountRecord(
            id: .init("removed"),
            principalID: .init("owner"),
            selfID: .init("self"),
            label: "Account",
            isEnabled: false,
            credentialGeneration: "one",
            isRemoving: true
        )
        record.forgetsSettings = true
        try registry.save(record)
        let suite = "com.entersprite.kibble.test.policy." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let key = "personalPreferences.v1.namespace.self"
        preferences.set(["skinTone": 2], forKey: key)
        preferences.set(["skinTone": 3], forKey: "personalPreferences.v1.namespace.other")
        let service = ChatService(
            registry: registry,
            storage: CleanupStorage(),
            providers: CleanupProviders(),
            policies: NativeAccountPolicies(base: registry, namespace: "namespace.", preferenceSuite: suite)
        )
        try await service.restore()
        for _ in 0 ..< 1000 {
            if try registry.accounts().isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try registry.accounts().isEmpty)
        #expect(preferences.object(forKey: key) == nil)
        #expect(preferences.object(forKey: "personalPreferences.v1.namespace.other") != nil)
        await service.shutdown()
    }

    private struct CleanupStorage: ServiceStorageFactory {
        func open(_: ConnectedAccountID) throws -> any ServiceAccountStorage {
            throw ServiceFailure
                .accountDisabled
        }

        func erase(_: ConnectedAccountID) throws {}
    }

    private struct CleanupProviders: AccountProviderFactory {
        func makeProvider(for _: AccountRecord) async throws -> AccountProvider {
            throw ServiceFailure
                .accountDisabled
        }

        func forgetCredentials(for _: AccountRecord) async throws {}
    }
}
