import ChatAPI
import Foundation
import ServiceClient

struct FilePolicyReplicaStorage: PolicyReplicaStorage {
    let file: URL

    func load() throws -> PolicyReplicaDocument? {
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
            return try ServiceCodec.decode(PolicyReplicaDocument.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func save(_ document: PolicyReplicaDocument) throws {
        // The session owns the directory. Never create it from a late callback.
        try ServiceCodec.encode(document).write(to: file, options: .atomic)
    }
}

enum LocalServiceIdentity {
    /// Called only under the host's exclusive service-directory lease.
    static func loadOrCreate(in directory: URL) throws -> ServiceInstanceID {
        let file = directory.appendingPathComponent("instance.json")
        if FileManager.default.fileExists(atPath: file.path) {
            return try ServiceCodec.decode(ServiceInfo.self, from: Data(contentsOf: file)).instanceID
        }
        let id = ServiceInstanceID(UUID().uuidString)
        try ServiceCodec.encode(ServiceInfo(instanceID: id)).write(to: file, options: .atomic)
        return id
    }
}
