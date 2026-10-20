import ChatAPI
import ChatKit
import ChatService
import Foundation
import LocalBridgeBackend

extension SystemLaunchServices {
    /// Each enabled account owns a separate provider and native media binding.
    static func accountProvider(
        for account: AccountRecord, custody: LocalAccountCustody,
        directory: URL, device: ServiceDeviceID, bindings: NativeAccountCallBindings
    ) async throws -> AccountProvider {
        let store = try await custody.credentialStore(for: account)
        let summary: StoredSessionSummary?
        let backend: LocalBridgeBackend?
        do {
            summary = try await store.summary(at: Date())
            backend = try await LocalBridgeBackend.using(
                store, connectivity: .native(), proof: .native, diagnostics: .native,
                meetingMetadataCacheURL: directory.appendingPathComponent("meeting-metadata.json")
            )
            let current = try await store.summary(at: Date())
            guard current?.capturedAt == summary?.capturedAt,
                  current?.expiresAt == summary?.expiresAt else {
                throw MeetDMCallTrialError.accountChanged
            }
        } catch ChatError.sessionExpired {
            throw ChatError.sessionExpired
        } catch {
            throw ChatError.unknown(KeychainDiagnosis.explain(error))
        }
        guard let backend, let summary else { throw ServiceFailure.authenticationRequired }
        let binding = NativeAccountCallBinding()
        let source = await backend.makeAudioCallService(
            store: store, expectedSession: summary, mediaFactory: { binding.makeMedia() }
        )
        await binding.install(source)
        bindings.install(binding, for: account)
        return AccountProvider(backend: backend, calls: [device: NativeAccountAudioCalls(
            source: source, binding: binding
        )])
    }
}

actor NativeAccountProviders: AccountProviderFactory {
    let custody: LocalAccountCustody
    let directory: URL
    let device: ServiceDeviceID
    let bindings: NativeAccountCallBindings

    init(
        custody: LocalAccountCustody, directory: URL,
        device: ServiceDeviceID, bindings: NativeAccountCallBindings
    ) {
        self.custody = custody; self.directory = directory
        self.device = device; self.bindings = bindings
    }

    func makeProvider(for account: AccountRecord) async throws -> AccountProvider {
        let component = Data(account.id.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let folder = directory.appendingPathComponent(component)
            .appendingPathComponent(LegacyAccountMigration.component(account.currentRevision.rawValue))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await SystemLaunchServices.accountProvider(
            for: account, custody: custody, directory: folder, device: device, bindings: bindings
        )
    }

    func forgetCredentials(for account: AccountRecord) async throws {
        try await custody.eraseGeneration(account: account.id, generation: account.credentialGeneration)
    }
}
