import AppCore
import AppKit
import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import LocalBridgeBackend

extension SystemAccountHost {
    func migrateLegacy(
        into directory: URL, instance: ServiceInstanceID,
        registry: SQLiteAccountRegistry, custody: LocalAccountCustody
    ) async throws {
        if let identifier = Bundle.main.bundleIdentifier {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count <= 1 else {
                throw ServiceFailure.accountCleanupPending
            }
        }
        let source = try SystemLaunchServices.supportDirectory()
        let legacy = KeychainCredentialStore(
            storage: PreservedLegacySessionStorage(), account: KeychainCredentialStore.defaultAccount
        )
        let services = SystemLaunchServices(arguments: .init(backend: .local))
        try await LegacyAccountMigration(
            source: source, destination: directory, instance: instance, principal: .init("local-owner"),
            adoption: NativeLegacyAccountAdoption(custody: custody, legacy: legacy),
            registry: registry, legacy: legacy, preferences: .standard,
            legacyAttachments: services.attachmentCacheDirectory()
        ).run()
    }

    func beginSignIn(replacing account: ConnectedAccountID? = nil) async {
        guard !isDeletingUserData, usesGoogleAccounts, let workspace, let service, let custody,
              let context else { return }
        if let captureWindow {
            captureWindow.show(); return
        }
        do {
            if workspace.capture == nil {
                try await workspace.beginLink(replacing: account)
            }
            guard let link = workspace.capture else { return }
            let intent = try await service.captureIntent(link.id, context: context)
            let store = try await custody.captureStore(for: intent)
            let scope = generation
            let model = CookieCaptureModel(
                autoSaveAllowed: true, custody: KeychainCaptureCustody(store: store),
                reportDirectory: nil, preparesCalls: true
            ) { [weak self, weak workspace] in
                guard let self, let workspace, generation == scope else { return }
                await finishSignIn(workspace, replacing: account)
            }
            let title = account.flatMap { workspace.accountLabels[$0] }.map { "Reconnect \($0)" }
                ?? "Add Google Account"
            let window = AccountSignInWindow(model: model, title: title) { [weak self, weak workspace] in
                guard let self, generation == scope else { return }
                captureWindow = nil
                do { try await workspace?.cancelCapture() } catch {
                    self.error = "Account sign-in cleanup is pending. Try again."
                }
            }
            captureWindow = window
            window.show()
        } catch { self.error = "Account sign-in could not open. Try again." }
    }

    /// After the browser hands over a sign-in: an account already in Kibble is
    /// shown, and another identity than the reconnecting account's is refused.
    private func finishSignIn(_ workspace: AccountWorkspace, replacing account: ConnectedAccountID?) async {
        do {
            let summary = try await workspace.completeCapture()
            captureWindow?.close()
            captureWindow = nil
            if summary?.phase == "alreadyConnected", let existing = summary?.accountID {
                workspace.select(existing)
                error = "That Google account is already in Kibble."
            }
        } catch let failure as ServiceFailure where failure == .wrongIdentity {
            // The service installed nothing. This attempt's capture is
            // discarded, and the next sign-in starts fresh.
            captureWindow?.close()
            captureWindow = nil
            try? await workspace.cancelCapture()
            refusedSignIn = account?.rawValue
        } catch { self.error = "This account could not be verified. Try signing in again." }
    }
}

/// Reading the old rename fallback must not move or erase the original item.
private struct PreservedLegacySessionStorage: SecretStorage {
    func read(account: String) throws -> Data? {
        try KeychainSecretStorage(service: KeychainCredentialStore.defaultService).read(account: account)
            ?? KeychainSecretStorage(service: "com.entersprite.gchat.session").read(account: account)
    }

    func write(_: Data, account _: String) throws {
        throw SessionCustodyError.sessionChanged
    }

    func delete(account _: String) throws {
        throw SessionCustodyError.sessionChanged
    }
}
