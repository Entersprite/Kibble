import Foundation
import Testing
@testable import MacHost

@MainActor
struct MeetingCacheErasureTests {
    @Test func erasureRemovesTheLookupCacheAndAllowsAnAlreadyMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("private cached metadata".utf8).write(to: url)
        try SystemLaunchServices.removeMeetingMetadataCache(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try SystemLaunchServices.removeMeetingMetadataCache(at: url)
    }
}
