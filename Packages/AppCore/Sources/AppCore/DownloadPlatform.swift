import Foundation

/// The folder finished downloads are placed in.
public struct DownloadFolder: Equatable, Sendable {
    public var url: URL
    /// Whether this is the system's Downloads folder rather than one the
    /// person chose.
    public var isDefault: Bool
    /// Said once, when the chosen folder could not be used and Downloads was used instead.
    public var notice: String?

    public init(url: URL, isDefault: Bool, notice: String? = nil) {
        self.url = url
        self.isDefault = isDefault
        self.notice = notice
    }
}

/// Everything a download needs from the platform and nothing else: the folder
/// and the way to choose it, the folder's sandbox access, and Finder and the
/// save panel. Declared here so AppCore links no AppKit, implemented by
/// MacHost (`SystemDownloadPlatform`); a future iOS app implements it with the
/// file exporter.
@MainActor
public protocol DownloadPlatform: AnyObject {
    var folder: DownloadFolder { get }
    func chooseFolder()
    func useDefaultFolder()
    /// Runs `body` with the folder's URL while access to it is held.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
    func open(_ file: URL)
    func reveal(_ file: URL)
    /// Asks where to save a copy; `nil` when the person cancelled.
    func chooseSaveDestination(suggestedName: String) -> URL?
}

/// The download folder exists in settings but cannot be written to - its
/// sandbox access was lost, or it was removed. Carries the folder's name only,
/// never its path, because the name is what a chip shows.
public struct DownloadFolderUnavailable: Error, Equatable {
    public let folderName: String

    public init(folderName: String) {
        self.folderName = folderName
    }
}
