import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import LocalBridgeBackend
import SyncEngine

/// Runs under exclusive service ownership, before either launch path has writers.
/// Originals remain available for recovery; publishing the registry is the final step.
@MainActor
struct LegacyAccountMigration {
    struct Intent: Codable {
        let account: ConnectedAccountID
        let generation: String
        var record: AccountRecord?
        var complete = false
    }

    let source: URL
    let destination: URL
    let instance: ServiceInstanceID
    let principal: ServicePrincipalID
    let adoption: any LegacyAccountAdoption
    let registry: SQLiteAccountRegistry
    let legacy: KeychainCredentialStore
    let preferences: UserDefaults
    func run() async throws {
        let journal = destination.appendingPathComponent("legacy-migration.json")
        var intent = try FileManager.default.fileExists(atPath: journal.path)
            ? ServiceCodec.decode(Intent.self, from: Data(contentsOf: journal))
            : Intent(account: .init(UUID().uuidString), generation: UUID().uuidString)
        guard !intent.complete else { return }
        try save(intent, to: journal)
        if try registry.accounts().contains(where: { $0.id == intent.account }) {
            intent.complete = true
            try save(intent, to: journal)
            return
        }
        let installed = try await adoption.installedIdentity(
            account: intent.account, generation: intent.generation
        )
        if installed == nil {
            guard try await legacy.summary(at: Date()) != nil else {
                intent.complete = true; try save(intent, to: journal); return
            }
            let identity = try await adoption.verify()
            if let record = intent.record, record.selfID != identity {
                throw ServiceFailure.notAuthorized
            }
            intent.record = intent.record ?? AccountRecord(
                id: intent.account, principalID: principal, selfID: identity,
                label: "Google account", credentialGeneration: intent.generation
            )
            try save(intent, to: journal)
            try await adoption.install(account: intent.account, generation: intent.generation)
        }
        guard let record = intent.record,
              try await adoption.installedIdentity(
                  account: intent.account, generation: intent.generation
              ) == record.selfID else { throw ServiceFailure.notAuthorized }
        try copyData(for: record)
        try copyPolicy(for: record)
        try registry.save(record)
        intent.complete = true
        try save(intent, to: journal)
    }

    private func copyData(for record: AccountRecord) throws {
        let component = Self.component(record.id.rawValue)
        let serviceFolder = destination.appendingPathComponent("service").appendingPathComponent(component)
        let clientFolder = destination.appendingPathComponent("clients").appendingPathComponent(component)
        for folder in [serviceFolder, clientFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let database = source.appendingPathComponent("chat-local.sqlite")
        if FileManager.default.fileExists(atPath: database.path) {
            for target in [
                serviceFolder.appendingPathComponent("service.sqlite"),
                clientFolder.appendingPathComponent("replica.sqlite")
            ] where !FileManager.default.fileExists(atPath: target.path) {
                try ChatStore.copyLegacyDatabase(from: database, to: target, identity: record.selfID)
            }
        }
        let summary = AccountSummary(
            id: record.id, selfID: record.selfID, label: record.label,
            connection: .idle, revision: record.currentRevision
        )
        try ServiceCodec.encode(summary).write(
            to: clientFolder.appendingPathComponent("binding.json"), options: .atomic
        )
        try ServiceCodec.encode(record.id).write(
            to: destination.appendingPathComponent("selection.json"), options: .atomic
        )
        let providerFolder = destination.appendingPathComponent("providers").appendingPathComponent(component)
            .appendingPathComponent(Self.component(record.currentRevision.rawValue))
        try FileManager.default.createDirectory(at: providerFolder, withIntermediateDirectories: true)
        try copyIfNeeded(
            source.appendingPathComponent("meeting-metadata-local.json"),
            to: providerFolder.appendingPathComponent("meeting-metadata.json")
        )
        if let attachments = legacyAttachments {
            try copyIfNeeded(attachments, to: clientFolder.appendingPathComponent("attachments"))
        }
    }

    var legacyAttachments: URL?

    private func copyPolicy(for record: AccountRecord) throws {
        let file = source.appendingPathComponent("notification-settings")
            .appendingPathComponent(FileNotificationSettingsStore.fileName(for: record.selfID))
        if FileManager.default.fileExists(atPath: file.path),
           try registry.policy(for: record).revision == "0" {
            let settings = try JSONDecoder().decode(NotificationSettings.self, from: Data(contentsOf: file))
            _ = try registry.setPolicy(settings, for: record, expectedRevision: "0")
        }
        let oldKey = "personalPreferences.v1." + record.selfID.rawValue
        let newKey = try "personalPreferences.v1." + (ServiceCodec.encode(instance).base64EncodedString())
            + "." + record.selfID.rawValue
        if preferences.object(forKey: newKey) == nil, let value = preferences.object(forKey: oldKey) {
            preferences.set(value, forKey: newKey)
        }
    }

    private func copyIfNeeded(_ from: URL, to: URL) throws {
        guard FileManager.default.fileExists(atPath: from.path),
              !FileManager.default.fileExists(atPath: to.path) else { return }
        let temporary = to.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: from, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: to)
    }

    private func save(_ intent: Intent, to file: URL) throws {
        try ServiceCodec.encode(intent).write(to: file, options: .atomic)
    }

    nonisolated static func component(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

protocol LegacyAccountAdoption: Sendable {
    func installedIdentity(account: ConnectedAccountID, generation: String) async throws -> Member.ID?
    func verify() async throws -> Member.ID
    func install(account: ConnectedAccountID, generation: String) async throws
}

actor NativeLegacyAccountAdoption: LegacyAccountAdoption {
    let custody: LocalAccountCustody
    let legacy: KeychainCredentialStore
    private var candidate: VerifiedProviderSession?

    init(custody: LocalAccountCustody, legacy: KeychainCredentialStore) {
        self.custody = custody; self.legacy = legacy
    }

    func installedIdentity(account: ConnectedAccountID, generation: String) async throws -> Member.ID? {
        try await custody.installedLegacyIdentity(account: account, generation: generation)
    }

    func verify() async throws -> Member.ID {
        let candidate = try await legacy.verify()
        self.candidate = candidate
        return candidate.selfID
    }

    func install(account: ConnectedAccountID, generation: String) async throws {
        guard let candidate else { throw ServiceFailure.notAuthorized }
        try await custody.adoptLegacy(candidate, account: account, generation: generation)
    }
}
