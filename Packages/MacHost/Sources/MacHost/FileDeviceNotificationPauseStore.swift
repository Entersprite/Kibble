import AppCore
import ChatAPI
import ChatKit
import Foundation

struct FileDeviceNotificationPauseStore: DeviceNotificationPauseStore {
    let file: URL
    func load() throws -> Pause? {
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 else { throw ServiceFailure.frameTooLarge }
            return try ServiceCodec.decode(Pause.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func save(_ pause: Pause) throws {
        try ServiceCodec.encode(pause).write(to: file, options: .atomic)
    }
}
