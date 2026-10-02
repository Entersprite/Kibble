import AppCore
import AppKit
import Foundation
import Observation

/// AppKit's half of a download: the folder (Downloads, or one the person
/// picked, kept as a security-scoped bookmark beside the database), sandbox
/// access around each placement, Finder, and the save panel.
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

    public func chooseSaveDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
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
