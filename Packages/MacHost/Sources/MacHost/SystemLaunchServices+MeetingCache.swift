import Foundation

extension SystemLaunchServices {
    static func meetingMetadataCacheURL() throws -> URL {
        try supportDirectory().appendingPathComponent("meeting-metadata-local.json")
    }

    static func removeMeetingMetadataCache(at location: URL? = nil) throws {
        do {
            try FileManager.default.removeItem(at: location ?? meetingMetadataCacheURL())
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
