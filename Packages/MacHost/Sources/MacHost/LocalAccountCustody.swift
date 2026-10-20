import ChatAPI
import ChatKit
import ChatService
import Foundation
import LocalBridgeBackend

/// Host vault ownership, namespaced by service installation and opaque IDs.
/// One actor owns all facades so a retired capture handle stays fenced.
public actor LocalAccountCustody: AccountLinkCustody {
    private let storage: any SecretStorage
    private let namespace: String
    private var stores: [String: KeychainCredentialStore] = [:]
    private var retiredKeys: Set<String> = []
    private var candidates: [AccountLinkID: VerifiedProviderSession] = [:]

    public init(storage: any SecretStorage, instanceID: ServiceInstanceID) throws {
        self.storage = storage
        namespace = try Self.component(instanceID.rawValue)
    }

    public func captureStore(for link: AccountLinkRecord) throws -> KeychainCredentialStore {
        try staging(link)
    }

    public func verify(_ link: AccountLinkRecord) async throws -> VerifiedLinkIdentity {
        let candidate = try await staging(link).verify()
        candidates[link.id] = candidate
        return VerifiedLinkIdentity(selfID: candidate.selfID, label: "Google account")
    }

    public func install(_ link: AccountLinkRecord) async throws {
        guard let identity = link.selfID else { throw ServiceFailure.invalidRequest }
        let destination = try generationStore(account: link.accountID, generation: link.generation)
        if let installed = try await destination.installedIdentity() {
            guard installed == identity else { throw ServiceFailure.operationConflict }
            return
        }
        let candidate: VerifiedProviderSession = if let cached = candidates[link.id] {
            cached
        } else {
            try await staging(link).verify()
        }
        guard candidate.selfID == identity else { throw ServiceFailure.operationConflict }
        try await destination.install(candidate, generation: link.generation)
    }

    public func discardStaging(_ link: AccountLinkRecord) async throws {
        candidates[link.id] = nil
        try await retire(key: stagingKey(link), generation: nil)
    }

    public func eraseGeneration(account: ConnectedAccountID, generation: String) async throws {
        try await retire(key: generationKey(account, generation: generation), generation: generation)
    }

    /// Provider construction receives only the exact committed generation and
    /// refuses vault metadata for a different provider identity.
    public func credentialStore(for account: AccountRecord) async throws -> KeychainCredentialStore {
        let store = try generationStore(account: account.id, generation: account.credentialGeneration)
        guard try await store.installedIdentity() == account.selfID
        else { throw ServiceFailure.notAuthorized }
        return store
    }

    /// Installs a sealed provider-verified legacy login without changing its source.
    public func adoptLegacy(
        _ candidate: VerifiedProviderSession, account: ConnectedAccountID, generation: String
    ) async throws {
        try await generationStore(account: account, generation: generation)
            .install(candidate, generation: generation)
    }

    public func installedLegacyIdentity(
        account: ConnectedAccountID, generation: String
    ) async throws -> ChatKit.Member.ID? {
        try await generationStore(account: account, generation: generation).installedIdentity()
    }

    private func staging(_ link: AccountLinkRecord) throws -> KeychainCredentialStore {
        try store(key: stagingKey(link), generation: nil)
    }

    private func generationStore(
        account: ConnectedAccountID,
        generation: String
    ) throws -> KeychainCredentialStore {
        try store(key: generationKey(account, generation: generation), generation: generation)
    }

    private func stagingKey(_ link: AccountLinkRecord) throws -> String {
        try "\(namespace).link.\(Self.component(link.id.rawValue))"
    }

    private func generationKey(_ account: ConnectedAccountID, generation: String) throws -> String {
        try "\(namespace).account.\(Self.component(account.rawValue)).\(Self.component(generation))"
    }

    private func store(key: String, generation: String?) throws -> KeychainCredentialStore {
        guard !retiredKeys.contains(key) else { throw SessionCustodyError.sessionChanged }
        if let existing = stores[key] {
            return existing
        }
        let result = KeychainCredentialStore(storage: storage, account: key, expectedGeneration: generation)
        stores[key] = result
        return result
    }

    private func retire(key: String, generation: String?) async throws {
        let store = stores[key] ?? KeychainCredentialStore(
            storage: storage,
            account: key,
            expectedGeneration: generation
        )
        retiredKeys.insert(key)
        stores[key] = nil
        try await store.retire()
    }

    private static func component(_ raw: String) throws -> String {
        let bytes = Data(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= 120 else { throw ServiceFailure.invalidRequest }
        return bytes.base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}
