import ChatAPI
import ChatService
import Foundation

public struct SQLiteServiceStorageFactory: ServiceStorageFactory {
    private let directory: URL
    private let retention: Int

    public init(directory: URL, retention: Int = 4096) {
        self.directory = directory
        self.retention = retention
    }

    public func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
        let folder = try accountDirectory(account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try SQLiteAccountStorage(
            account: account,
            path: folder.appendingPathComponent("service.sqlite").path,
            retention: retention
        )
    }

    public func erase(_ account: ConnectedAccountID) throws {
        let folder = try accountDirectory(account)
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private func accountDirectory(_ account: ConnectedAccountID) throws -> URL {
        let data = Data(account.rawValue.utf8)
        guard !data.isEmpty, data.count <= 120 else { throw ServiceFailure.invalidRequest }
        let name = data.base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(name, isDirectory: true)
    }
}
