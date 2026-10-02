import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// The download coordinator's place in a session: built with the engine,
/// offered to the chip only when the backend can download files, and stopped
/// on every path into sign-in (`enterNeedsSignIn`). Settings › Downloads reads
/// the folder through it while a session runs and from the platform otherwise.
extension AppEnvironment {
    /// Staged under the temporary directory, so a crash leaves nothing in
    /// the person's folder and the system eventually clears what it leaves.
    ///
    /// One staging directory per session, not one shared: `stopAll()` removes
    /// its whole staging directory, and a shared one would take another
    /// session's transfer in flight with it - a second process on the same
    /// container, or another test.
    func makeDownloads(engine: SyncEngine) -> DownloadCoordinator {
        DownloadCoordinator(
            staging: FileManager.default.temporaryDirectory
                .appendingPathComponent("kibble-downloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true),
            platform: services.downloadPlatform()
        ) { [engine] attachment, destination, progress in
            try await engine.downloadAttachment(attachment, to: destination, progress: progress)
        }
    }

    /// Cancels every running transfer and drops the coordinator. Files
    /// already placed are the person's and stay (`DownloadCoordinator.stopAll`).
    func stopDownloads() {
        downloads?.stopAll()
        downloads = nil
    }

    var canDownloadFiles: Bool {
        runningModel?.capabilities.canDownloadFiles == true
    }

    /// `nil` unless the backend can download files: a chip with no actions
    /// draws no control (`CLAUDE.md`, never draw a control the seam cannot honour).
    ///
    /// Each closure reads `downloads` through `self` at call time rather than
    /// capturing this session's coordinator, for `loadAttachment`'s reason: a
    /// view still on screen during sign-out holds the closure it was given,
    /// and must not start a transfer on the session that just ended.
    var attachmentFileActions: AttachmentFileActions? {
        guard canDownloadFiles, downloads != nil else { return nil }
        return AttachmentFileActions(
            download: { [weak self] in self?.downloads?.start($0) },
            cancel: { [weak self] in self?.downloads?.cancel($0) },
            open: { [weak self] in self?.downloads?.open($0) },
            reveal: { [weak self] in self?.downloads?.reveal($0) },
            saveAs: { [weak self] in self?.downloads?.saveAs($0) }
        )
    }

    /// Through the coordinator when a session has one, so its own copy of
    /// the folder follows the choice; straight to the platform otherwise.
    func chooseDownloadFolder() {
        if let downloads {
            downloads.chooseFolder()
        } else {
            services.downloadPlatform().chooseFolder()
        }
    }

    func useDefaultDownloadFolder() {
        if let downloads {
            downloads.useDefaultFolder()
        } else {
            services.downloadPlatform().useDefaultFolder()
        }
    }
}

public extension AppEnvironment {
    /// The path is resolved for display only - in the sandbox the default
    /// folder is a symlink inside the container, which is not where a person
    /// would look. Writing still goes through `folder.url`, untouched.
    var downloadSettingsState: DownloadSettingsState {
        let folder = downloads?.folder ?? services.downloadPlatform().folder
        let shown = folder.url.resolvingSymlinksInPath().path(percentEncoded: false)
        return DownloadSettingsState(
            folderName: FileManager.default.displayName(atPath: shown),
            folderPath: shown,
            isDefault: folder.isDefault,
            notice: folder.notice
        )
    }

    var downloadSettingsActions: DownloadSettingsActions {
        DownloadSettingsActions(
            choose: { [weak self] in self?.chooseDownloadFolder() },
            useDefault: { [weak self] in self?.useDefaultDownloadFolder() }
        )
    }
}
