import AppCore
import AppKit
import ChatService
import ChatServiceStorage
import Foundation
import LocalBridgeBackend
import UserNotifications
import WebKit

public extension MacAppDelegate {
    /// Invoked only after the native destructive confirmation. Stops writers
    /// before erasure; the pending marker prevents legacy-login resurrection
    /// and resumes an interrupted deletion on the next launch.
    func deleteAllUserData() async throws {
        guard !deletingUserData else { return }
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            throw CocoaError(.fileWriteNoPermission)
        }
        deletingUserData = true
        accountHost?.isDeletingUserData = true
        defer {
            deletingUserData = false
            accountHost?.isDeletingUserData = false
        }
        let directory = try SystemLaunchServices.supportDirectory()
        let erasure = UserDataErasure(directory: directory)
        var lease: (any ServiceOwnershipLease)?
        defer { lease?.release() }
        try await erasure.run(stoppingWriters: {
            try await stopForDataErasure()
            // Preserve the service's advisory lock inode throughout erasure.
            let ownership = try FileServiceOwnership(file: directory.appendingPathComponent(
                accountHost?.usesGoogleAccounts == false
                    ? "MultiAccountFixture/service.lock" : "Accounts/service.lock"
            ))
            lease = try ownership.acquire()
        }, erasingNativeData: {
            try await eraseNativePrivateData()
        }, clearingPreferences: {
            try clearPreferencesForDataErasure()
        })
        if accountHost?.usesGoogleAccounts != false {
            diagnostics.start()
        }
        lease?.release()
        if let host = accountHost {
            host.isDeletingUserData = false
            await host.start()
            startAccountCalls()
            if host.usesGoogleAccounts {
                await host.addAccount()
            }
        }
    }

    private func clearPreferencesForDataErasure() throws {
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        let fixture = UserDefaults(suiteName: "com.entersprite.kibble.multi-account-fixture")
        fixture?.removePersistentDomain(forName: "com.entersprite.kibble.multi-account-fixture")
        callSettings.reset()
        updates.reset()
        guard UserDefaults.standard.synchronize(), fixture?.synchronize() != false else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func stopForDataErasure() async throws {
        diagnostics.clearAndSuspend()
        NotificationSoundLibrary.stopPreview()
        legacyEnvironment.downloadSettingsActions.useDefault()
        callSounds.stop()
        callRinger.stop()
        callAlerts?.update(call: nil, rule: nil, paused: true)
        callResponseTask?.cancel()
        callCamera.cancel()
        await accountCalls?.stop()
        accountCalls = nil
        await callSignIn.invalidate()
        if let host = accountHost {
            let custody = host.custody
            let registry = host.registry
            await host.stop()
            try await custody?.retireAll()
            try registry?.close()
        } else {
            await legacyEnvironment.signOut()
            guard case .needsSignIn = legacyEnvironment.phase else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private func eraseNativePrivateData() async throws {
        if accountHost?.usesGoogleAccounts != false {
            try KeychainSecretStorage(service: KeychainCredentialStore.defaultService).deleteAll()
            try KeychainSecretStorage(service: "com.entersprite.gchat.session").deleteAll()
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        for (space, credentials) in URLCredentialStorage.shared.allCredentials {
            for credential in credentials.values {
                URLCredentialStorage.shared.remove(credential, for: space)
            }
        }
        try eraseInstalledNotificationSounds()
        try UserDataErasure.eraseTemporaryFiles(in: FileManager.default.temporaryDirectory)
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
           let identifier = Bundle.main.bundleIdentifier {
            let state = library.appendingPathComponent("Saved Application State")
                .appendingPathComponent(identifier + ".savedState")
            if FileManager.default
                .fileExists(atPath: state.path) {
                try FileManager.default.removeItem(at: state)
            }
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let owned = caches.appendingPathComponent("Kibble", isDirectory: true)
            if FileManager.default
                .fileExists(atPath: owned.path) {
                try FileManager.default.removeItem(at: owned)
            }
        }
    }

    private func eraseInstalledNotificationSounds() throws {
        let directory = try MessageNotificationSound.libraryDirectory().appendingPathComponent("Sounds")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for file in files {
            let name = file.lastPathComponent
            let custom = name.hasPrefix(NotificationSoundLibrary.prefix) && name.hasSuffix(".aiff")
                &&
                UUID(uuidString: String(name.dropFirst(NotificationSoundLibrary.prefix.count)
                        .dropLast(5))) != nil
            if name == MessageNotificationSound.filename || custom {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
