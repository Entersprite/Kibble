import Foundation

/// Checked, restartable erasure of an explicitly owned directory. No external
/// URL or download destination is ever passed to this operation.
struct UserDataErasure {
    let directory: URL
    static let markerName = "erase-user-data.pending"

    var marker: URL {
        directory.appendingPathComponent(Self.markerName)
    }

    var isPending: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    @MainActor
    func run(
        stoppingWriters: () async throws -> Void,
        erasingNativeData: () async throws -> Void,
        clearingPreferences: () throws -> Void
    ) async throws {
        try begin()
        try await stoppingWriters()
        try await erasingNativeData()
        try eraseFiles()
        try clearingPreferences()
        try finish()
    }

    func begin() throws {
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// Keep advisory lock inodes and the pending marker until every phase
    /// succeeds. removeItem removes a symbolic link itself, never its target.
    func eraseFiles() throws {
        try Self.empty(directory, keeping: [
            Self.markerName, "Accounts/service.lock", "MultiAccountFixture/service.lock"
        ])
    }

    func finish() throws {
        try FileManager.default.removeItem(at: marker)
    }

    /// Staging locations created by the composer/download owners, including
    /// leftovers from a crash. Never follows a link into a chosen download folder.
    static func eraseTemporaryFiles(in temporary: URL) throws {
        guard FileManager.default.fileExists(atPath: temporary.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ) {
            let name = child.lastPathComponent
            let replacement = name.hasPrefix("kibble-replace-")
                && UUID(uuidString: String(name.dropFirst("kibble-replace-".count))) != nil
            if name == "Pasted Images" || name == "kibble-downloads" || replacement {
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    static func empty(_ directory: URL, keeping paths: Set<String> = []) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        for child in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) {
            let name = child.lastPathComponent
            if paths.contains(name) {
                continue
            }
            let descendants = Set(paths
                .compactMap { $0.hasPrefix(name + "/") ? String($0.dropFirst(name.count + 1)) : nil })
            if descendants.isEmpty {
                try FileManager.default.removeItem(at: child)
            } else {
                try empty(child, keeping: descendants)
            }
        }
    }
}
