import AppCore
import AppKit
import Foundation
import Observation

/// AppKit's half of a download: the folder (Downloads, or one the person
/// picked, kept as a security-scoped bookmark beside the database), sandbox
/// access around each placement, Finder, the save panel, and the alert a
/// failed Save As shows.
///
/// `@Observable` so Settings › Downloads redraws when the folder changes with
/// no session running, when it reads `folder` here rather than through a
/// `DownloadCoordinator`.
@MainActor
@Observable
public final class SystemDownloadPlatform: DownloadPlatform {
    public private(set) var folder: DownloadFolder
    private let bookmarkFile: URL?

    public init(bookmarkFile: URL?) {
        self.bookmarkFile = bookmarkFile
        folder = Self.resolve(bookmarkFile)
    }

    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = folder.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            if let bookmarkFile {
                try data.write(to: bookmarkFile, options: .atomic)
            }
            folder = DownloadFolder(url: url, isDefault: false)
        } catch {
            folder.notice = "Kibble couldn't remember “\(url.lastPathComponent)”, "
                + "so it is still saving to \(folder.url.lastPathComponent)."
        }
    }

    public func useDefaultFolder() {
        if let bookmarkFile {
            try? FileManager.default.removeItem(at: bookmarkFile)
        }
        folder = Self.defaultFolder(notice: nil)
    }

    /// Blames the folder only when the folder is the problem. A failure inside
    /// `body` becomes `DownloadFolderUnavailable` when it is a refused write -
    /// the sandbox access that was lost, which a POSIX check need not see -
    /// or when, with access still held, the folder is now missing or
    /// unwritable. Anything else propagates unchanged: a staged file that is
    /// gone says "no such file" too, and is not the folder's fault.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = folder.url
        let scoped = !folder.isDefault && url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // No check before `body`: a folder that cannot be used fails there,
        // and the catch below names it.
        do {
            return try body(url)
        } catch {
            if (error as? CocoaError)?.code == .fileWriteNoPermission || !Self.isUsableFolder(url) {
                throw DownloadFolderUnavailable(folderName: url.lastPathComponent)
            }
            throw error
        }
    }

    public func open(_ file: URL) {
        NSWorkspace.shared.open(file)
    }

    public func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// A sheet on the window the person chose Save As… in. The coordinator
    /// asks for the destination synchronously, so the sheet runs as an
    /// application-modal sheet - `beginSheetModal` then `runModal(for:)`,
    /// AppKit's own pattern - and answers before this returns. With no
    /// window free to take a sheet, the panel runs on its own, as before.
    public func chooseSaveDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard let window = Self.sheetWindow(), window.attachedSheet == nil else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        panel.beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: panel) == .OK ? panel.url : nil
    }

    /// A sheet on the same window as the save panel it follows. It needs no
    /// answer, so it is not modal to the app; AppKit queues it while the
    /// save panel's sheet is still closing.
    public func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let window = Self.sheetWindow() {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The window a sheet goes on: the key window, else the main one, while
    /// it is on screen and is not itself a sheet.
    static func sheetWindow(
        key: NSWindow? = NSApp.keyWindow, main: NSWindow? = NSApp.mainWindow
    ) -> NSWindow? {
        [key, main].compactMap(\.self).first { $0.isVisible && !$0.isSheet }
    }

    /// An existing directory this process may write into.
    static func isUsableFolder(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }

    /// The bookmarked folder, or Downloads when there is none. A folder that
    /// is gone is noticed, without its path, on every launch it stays gone:
    /// the bookmark is kept, because a removable drive may come back.
    static func resolve(_ bookmarkFile: URL?) -> DownloadFolder {
        guard let bookmarkFile, let data = try? Data(contentsOf: bookmarkFile) else {
            return defaultFolder(notice: nil)
        }
        let gone =
            defaultFolder(notice: "The folder Kibble was saving to is gone, so downloads go to Downloads.")
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return gone
        }
        // Held across the existence check, not only the refresh: in the App
        // Sandbox a folder outside the container cannot even be stat'ed
        // without its scope, so an unscoped check would read a chosen folder
        // as gone on every relaunch. [Verify] in a signed, sandboxed run - the
        // unsandboxed test runner cannot show the refusal.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return gone
        }
        if stale, scoped, let fresh = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            try? fresh.write(to: bookmarkFile, options: .atomic)
        }
        return DownloadFolder(url: url, isDefault: false)
    }

    static func defaultFolder(notice: String?) -> DownloadFolder {
        DownloadFolder(
            url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
            isDefault: true,
            notice: notice
        )
    }
}
