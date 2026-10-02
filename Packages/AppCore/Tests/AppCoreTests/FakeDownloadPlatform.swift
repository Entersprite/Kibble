import AppCore
import Foundation

/// A platform with a folder and no Finder: records what it was asked to open
/// and reveal, answers the save panel with `saveDestination`, and refuses
/// folder access when `accessFailure` is set.
@MainActor
final class FakeDownloadPlatform: DownloadPlatform {
    var folder: DownloadFolder
    var saveDestination: URL?
    var accessFailure: DownloadFolderUnavailable?
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    private(set) var suggestedNames: [String] = []

    init(folder: URL) {
        self.folder = DownloadFolder(url: folder, isDefault: true)
    }

    func chooseFolder() {}

    func useDefaultFolder() {}

    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        if let accessFailure {
            throw accessFailure
        }
        return try body(folder.url)
    }

    func open(_ file: URL) {
        opened.append(file)
    }

    func reveal(_ file: URL) {
        revealed.append(file)
    }

    func chooseSaveDestination(suggestedName: String) -> URL? {
        suggestedNames.append(suggestedName)
        return saveDestination
    }
}
