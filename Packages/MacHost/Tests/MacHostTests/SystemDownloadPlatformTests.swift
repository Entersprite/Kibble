import AppCore
import Foundation
import Testing
@testable import MacHost

/// The folder half of `SystemDownloadPlatform`: what a bookmark file resolves
/// to, and what `withAccess` blames on the folder. Every bookmark file lives
/// in a temporary directory, never the real support directory.
@MainActor
struct SystemDownloadPlatformTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "system-download-platform-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var bookmarkFile: URL {
        root.appending(path: "download-folder.bookmark")
    }

    private var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A chosen folder under `root`, with its bookmark written where the
    /// platform will look for it.
    private func chosenFolder(named name: String = "Chosen") throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try folder.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try data.write(to: bookmarkFile)
        return folder
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    @Test func withNoBookmarkTheFolderIsDownloads() {
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        #expect(platform.folder.isDefault)
        #expect(platform.folder.url == downloads)
        #expect(platform.folder.notice == nil)
    }

    @Test func aBookmarkForAnExistingFolderResolvesToIt() throws {
        defer { cleanUp() }
        let folder = try chosenFolder()
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        #expect(!platform.folder.isDefault)
        #expect(sameFile(platform.folder.url, folder))
        #expect(platform.folder.notice == nil)
    }

    @Test func aBookmarkWhoseFolderIsGoneFallsBackToDownloadsWithoutNamingThePath() throws {
        defer { cleanUp() }
        let folder = try chosenFolder(named: "Gone Folder")
        try FileManager.default.removeItem(at: folder)

        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)

        #expect(platform.folder.isDefault)
        #expect(platform.folder.url == downloads)
        let notice = try #require(platform.folder.notice)
        #expect(!notice.contains(folder.path(percentEncoded: false)))
        #expect(!notice.contains("Gone Folder"))
        #expect(!notice.contains(root.lastPathComponent))
    }

    @Test func usingTheDefaultFolderRemovesTheBookmark() throws {
        defer { cleanUp() }
        _ = try chosenFolder()
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        try #require(!platform.folder.isDefault)

        platform.useDefaultFolder()

        #expect(!exists(bookmarkFile))
        #expect(platform.folder.isDefault)
        #expect(platform.folder.url == downloads)
    }

    /// The reviewer's case: a missing *staged* file says "no such file" too,
    /// and must not be blamed on a folder that is still there.
    @Test func anErrorThatIsNotTheFoldersPassesThroughUnchanged() throws {
        defer { cleanUp() }
        _ = try chosenFolder()
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        try #require(!platform.folder.isDefault)

        #expect(throws: CocoaError(.fileNoSuchFile)) {
            try platform.withAccess { _ in throw CocoaError(.fileNoSuchFile) }
        }
    }

    /// A refused write is the sandbox access that was lost, folder intact or not.
    @Test func aRefusedWriteIsBlamedOnTheFolder() throws {
        defer { cleanUp() }
        _ = try chosenFolder()
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        try #require(!platform.folder.isDefault)

        #expect(throws: DownloadFolderUnavailable(folderName: "Chosen")) {
            try platform.withAccess { _ in throw CocoaError(.fileWriteNoPermission) }
        }
    }

    @Test func aFolderRemovedAfterLaunchIsReportedByName() throws {
        defer { cleanUp() }
        let folder = try chosenFolder()
        let platform = SystemDownloadPlatform(bookmarkFile: bookmarkFile)
        try #require(!platform.folder.isDefault)
        try FileManager.default.removeItem(at: folder)

        #expect(throws: DownloadFolderUnavailable(folderName: "Chosen")) {
            try platform.withAccess { folder in
                try Data("PDF".utf8).write(to: folder.appending(path: "a.pdf"))
            }
        }
    }
}
