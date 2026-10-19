import Foundation

public extension AppEnvironment {
    /// Detaches one client replica. Provider lifetime belongs to its service.
    /// Disabling retains disk state; authentication/removal require a checked
    /// erase before the account workspace can offer sign-in again.
    func detachClient(erasingPrivateData: Bool) async throws {
        await calls.stop()
        identityTask?.cancel()
        identityTask = nil
        settings.onChange = nil
        receiptGate = nil
        if let driver {
            await driver.stop(); self.driver = nil
        }
        await notifications?.detach()
        stopDownloads()
        if let attachments {
            self.attachments = nil
            retiredAttachments = attachments
            await attachments.retire()
        }
        if let model {
            if erasingPrivateData {
                try await model.stopAndEraseStore()
            } else {
                await model.stop()
            }
        } else if erasingPrivateData {
            try services.eraseStore()
        }
        if erasingPrivateData {
            try await retiredAttachments?.erasePrivateData()
            try services.eraseBackendCaches()
        }
        retiredAttachments = nil
        model = nil
        composerDrafts = [:]
        connectionService = nil
        switchAccount(to: nil)
        releasePresentationCaches()
        phase = .loading
    }
}
