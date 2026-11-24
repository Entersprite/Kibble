import Foundation

public struct MeetAgendaArtifact: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case notes, recording, transcription
    }

    public let kind: Kind
    public let title: String?
    public let url: URL
}

public struct MeetAgendaFiles: Sendable {
    public struct Attachment: Sendable {
        public let title: String?
        public let url: URL
    }

    public let artifacts: [MeetAgendaArtifact]
    public let attachments: [Attachment]
    public let guests: [MeetAgendaGuest]
}

enum MeetAgendaWire {
    static let method = "MeetingCalendarAgendaService/FetchCalendarEvent"

    static func event(
        _ body: Data,
        matching meetingURL: URL,
        requireConferenceLink: Bool = false
    ) throws -> Data? {
        let envelope = try MeetProto.decode(body)
        guard ProtoFieldScan.fields(in: envelope).fields.contains(where: { $0.number == 1 }) else {
            return nil
        }
        let event = try MeetProto.payload(1, envelope)
        try MeetProto.validate(event)
        if ProtoFieldScan.fields(in: event).fields.contains(where: { $0.number == 17 }) {
            guard let url = try URL(string: MeetProto.text(17, event)),
                  let link = try? MeetJoinLink(url), link.url == meetingURL else { return nil }
        } else if requireConferenceLink {
            return nil
        }
        return event
    }

    static func artifacts(_ event: Data) -> [MeetAgendaArtifact] {
        var urls = Set<URL>()
        return ProtoFieldScan.payloads(ofField: 19, in: event).prefix(64).compactMap { row in
            guard let artifact = artifact(row), urls.insert(artifact.url).inserted else { return nil }
            return artifact
        }
    }

    static func attachments(_ event: Data) -> [MeetAgendaFiles.Attachment] {
        var urls = Set<URL>()
        return ProtoFieldScan.payloads(ofField: 19, in: event).prefix(64).compactMap { row in
            guard (try? MeetProto.value(6, row)) == 1, isVisibleAttachment(row),
                  let value = try? MeetProto.text(1, row),
                  let url = fileURL(value, includeOfficeFiles: true),
                  urls.insert(url).inserted else { return nil }
            return MeetAgendaFiles.Attachment(title: title(row), url: url)
        }
    }

    private static func isVisibleAttachment(_ row: Data) -> Bool {
        if !ProtoFieldScan.fields(in: row).fields.contains(where: { $0.number == 7 }) {
            return true
        }
        guard let state = try? MeetProto.value(7, row) else { return false }
        return state == 0 || state == 1
    }

    private static func artifact(_ row: Data) -> MeetAgendaArtifact? {
        guard (try? MeetProto.value(7, row)) == 1,
              let kind = try? MeetProto.value(6, row),
              let value = try? MeetProto.text(1, row), let url = fileURL(value) else { return nil }
        let kinds: [UInt64: MeetAgendaArtifact.Kind] = [2: .notes, 3: .recording, 4: .transcription]
        guard let kind = kinds[kind] else { return nil }
        return MeetAgendaArtifact(kind: kind, title: title(row), url: url)
    }

    private static func title(_ row: Data) -> String? {
        (try? MeetProto.text(2, row)).flatMap { $0.utf8.count <= 512 ? $0 : nil }
    }

    private static func fileURL(_ value: String, includeOfficeFiles: Bool = false) -> URL? {
        guard value.utf8.count <= 2048, let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, let host = parts.host?.lowercased() else { return nil }
        let path = parts.percentEncodedPath
        let isFile = switch host {
        case "drive.google.com":
            hasFilePath(path, prefix: "/file/d/") || (path == "/open" && isFileID(
                parts.queryItems?.first { $0.name == "id" }?.value ?? ""
            ))
        case "docs.google.com":
            hasFilePath(path, prefix: "/document/d/") || (includeOfficeFiles && isOfficeFilePath(path))
        default: false
        }
        return isFile ? parts.url : nil
    }

    private static func isOfficeFilePath(_ path: String) -> Bool {
        ["/spreadsheets/d/", "/presentation/d/", "/drawings/d/", "/forms/d/"].contains {
            hasFilePath(path, prefix: $0)
        } || hasFilePath(path, prefix: "/forms/d/e/", endings: ["viewform"])
    }

    private static func hasFilePath(
        _ path: String,
        prefix: String,
        endings: [Substring] = ["", "view", "edit", "preview"]
    ) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let fields = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard let id = fields.first, isFileID(String(id)) else { return false }
        return fields.count == 1 || (fields.count == 2 && endings.contains(fields[1]))
    }

    private static func isFileID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122)
                .contains($0) || $0 == 45 || $0 == 95
        }
    }
}
