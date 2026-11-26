import ChatKit
import Foundation
import GChatBridgeCore

/// Provider-private lookup results. The host supplies and erases the location;
/// the credential factory binds it to the exact stored login capture.
struct MeetingMetadataCacheFile {
    let url: URL
    let scope: Date

    private enum Failure: Error { case oversized }

    private struct Contents: Codable {
        var version = 1
        let scope: Date
        let entries: [Entry]
    }

    private struct Entry: Codable {
        let id: Conversation.ID
        let title: String?
        let integrations: [Data]
        let checkedAt: Date
        let meeting: MeetingOccurrence?
    }

    func load(now: Date) -> [Conversation.ID: MeetingMetadataHydration.Cached] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_000_000, let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.version == 1, contents.scope == scope,
              contents.entries.count <= 1024 else { return [:] }
        var result: [Conversation.ID: MeetingMetadataHydration.Cached] = [:]
        for entry in contents.entries {
            // A result saved before its grouping scope was recorded is looked
            // up again, so it cannot combine with another context's meeting.
            guard entry.checkedAt.timeIntervalSince1970.isFinite,
                  entry.checkedAt <= now.addingTimeInterval(300),
                  entry.meeting?.isValid != false,
                  entry.meeting.map({ $0.seriesScope != nil }) != false,
                  let integrations = try? entry.integrations
                  .map({ try SpaceIntegrationPayload(serializedBytes: $0) })
            else { continue }
            result[entry.id] = .init(
                key: .init(revision: 0, title: entry.title, integrations: integrations),
                meeting: entry.meeting, checkedAt: entry.checkedAt
            )
        }
        return result
    }

    func save(_ cache: [Conversation.ID: MeetingMetadataHydration.Cached]) throws {
        let entries = try cache.sorted { $0.key.rawValue < $1.key.rawValue }.prefix(1024).map { id, value in
            try Entry(
                id: id,
                title: value.key.title,
                integrations: value.key.integrations.map { try $0.serializedData() },
                checkedAt: value.checkedAt,
                meeting: value.meeting
            )
        }
        let data = try JSONEncoder().encode(Contents(scope: scope, entries: entries))
        guard data.count <= 2_000_000 else { throw Failure.oversized }
        try data.write(to: url, options: .atomic)
    }
}

extension LocalBridgeBackend {
    func installMeetingMetadataCache(at url: URL, scope: Date) {
        meetingMetadataCacheFile = MeetingMetadataCacheFile(url: url, scope: scope)
    }

    func saveMeetingMetadataCache() {
        guard meetingMetadata.loadedCache else { return }
        do {
            try meetingMetadataCacheFile?.save(meetingMetadata.cache)
        } catch {
            diagnostics.record(.meetingCacheWriteFailed)
        }
    }
}
