import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import LocalBridgeBackend
import SyncEngine
import Testing
@testable import MacHost

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LegacyAccountMigrationTests {
    @Test func validLegacyLoginHistoryPolicyAndPreferencesSurviveResumableAdoption() async throws {
        let harness = try await MigrationHarness.make()
        let original = harness.secrets.read(account: "primary")
        let store = try ChatStore.onDisk(at: harness.source.appendingPathComponent("chat-local.sqlite").path)
        try store.apply([
            .setLocalMember(.init("verified-self")),
            .upsertMembers([.init(id: .init("verified-self"), kind: .human)]),
            .replaceConversations([.init(id: .init("chat"), kind: .directMessage, title: "Retained")])
        ])
        var settings = NotificationSettings()
        settings.setRule(
            .init(delivery: .off, readReceipts: false),
            for: .global,
            at: .distantPast,
            by: "device"
        )
        try FileNotificationSettingsStore(directory: harness.source).save(
            settings,
            for: .init("verified-self")
        )
        harness.preferences.set(["skinTone": 3], forKey: "personalPreferences.v1.verified-self")
        try await harness.migration.run()
        let record = try #require(try harness.registry.accounts().first)
        #expect(record.selfID.rawValue == "verified-self")
        #expect(harness.secrets.read(account: "primary") == original)
        #expect(try harness.registry.policy(for: record).settings == settings)
        let component = LegacyAccountMigration.component(record.id.rawValue)
        for path in ["service/\(component)/service.sqlite", "clients/\(component)/replica.sqlite"] {
            let copy = try ChatStore.onDisk(at: harness.destination.appendingPathComponent(path).path)
            #expect(try copy.me() == record.selfID)
            #expect(try copy.conversations().first?.title == "Retained")
        }
        let newKey = try "personalPreferences.v1." + (ServiceCodec.encode(ServiceInstanceID("installation")))
            .base64EncodedString() + ".verified-self"
        #expect(harness.preferences.dictionary(forKey: newKey)?["skinTone"] as? Int == 3)
        try await harness.migration.run()
        #expect(try harness.registry.accounts().count == 1)
        // A completed migration must never resurrect an account removed later.
        try harness.registry.remove(record.id)
        try await harness.migration.run()
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try store.me() == record.selfID)
    }

    @Test func aFailedCopyDoesNotPublishOrEraseAndInstalledVaultResumesWithoutNetwork() async throws {
        let harness = try await MigrationHarness.make()
        let path = harness.source.appendingPathComponent("chat-local.sqlite")
        let original = harness.secrets.read(account: "primary")
        let store = try ChatStore.onDisk(at: path.path)
        try store.apply([.setLocalMember(.init("another-person"))])
        await #expect(throws: (any Error).self) { try await harness.migration.run() }
        #expect(try harness.registry.accounts().isEmpty)
        #expect(harness.secrets.read(account: "primary") == original)
        try store.apply([.setLocalMember(.init("verified-self"))])
        await harness.adoption.failVerification()
        try await harness.migration.run()
        #expect(try harness.registry.accounts().count == 1)
        #expect(harness.secrets.read(account: "primary") == original)
    }

    @Test func offlineVerificationLeavesTheLegacyLoginAndRegistryUntouched() async throws {
        let harness = try await MigrationHarness.make()
        let original = harness.secrets.read(account: "primary")
        await harness.adoption.failVerification()
        await #expect(throws: ServiceFailure.deadlineExceeded) { try await harness.migration.run() }
        #expect(try harness.registry.accounts().isEmpty)
        #expect(harness.secrets.read(account: "primary") == original)
        await harness.adoption.allowVerification()
        try await harness.migration.run()
        #expect(try harness.registry.accounts().count == 1)
    }
}

@MainActor
private struct MigrationHarness {
    let source: URL
    let destination: URL
    let secrets: MigrationSecrets
    let registry: SQLiteAccountRegistry
    let preferences: UserDefaults
    let migration: LegacyAccountMigration
    let adoption: MigrationAdoption

    static func make() async throws -> Self {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = source.appendingPathComponent("Accounts")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let secrets = MigrationSecrets()
        let legacy = KeychainCredentialStore(storage: secrets, account: "primary")
        #expect(try await CookieCapture(cookies: [CapturedCookie(
            name: "SID", value: "synthetic", domain: ".google.com", path: "/", isSecure: true,
            isHTTPOnly: true, expiresAt: nil
        )], capturedAt: Date(), pageURL: "https://chat.google.com/", pageTitle: "Chat").save(to: legacy))
        let registry = try SQLiteAccountRegistry(path: destination.appendingPathComponent("registry.sqlite")
            .path)
        let preferences = try #require(UserDefaults(suiteName: "migration-test-" + UUID().uuidString))
        let adoption = MigrationAdoption()
        let migration = LegacyAccountMigration(
            source: source, destination: destination, instance: .init("installation"),
            principal: .init("owner"),
            adoption: adoption,
            registry: registry, legacy: legacy, preferences: preferences, legacyAttachments: nil
        )
        return Self(
            source: source,
            destination: destination,
            secrets: secrets,
            registry: registry,
            preferences: preferences,
            migration: migration, adoption: adoption
        )
    }
}

private final class MigrationSecrets: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) {
        lock.withLock { values[account] = data }
    }

    func delete(account: String) {
        lock.withLock { values[account] = nil }
    }
}

private actor MigrationAdoption: LegacyAccountAdoption {
    private var installed: [String: Member.ID] = [:]
    private var failing = false
    func failVerification() {
        failing = true
    }

    func allowVerification() {
        failing = false
    }

    func installedIdentity(account: ConnectedAccountID, generation: String) -> Member.ID? {
        installed[account.rawValue + generation]
    }

    func verify() throws -> Member.ID {
        if failing {
            throw ServiceFailure.deadlineExceeded
        }
        return .init("verified-self")
    }

    func install(account: ConnectedAccountID, generation: String) {
        installed[account.rawValue + generation] = .init("verified-self")
    }
}
