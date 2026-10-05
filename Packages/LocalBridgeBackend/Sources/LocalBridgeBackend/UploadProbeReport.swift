import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// `--probe=upload`: one upload of a generated 16×16 PNG into one real
/// conversation, through `AttachmentUpload`, **and nothing posted**. An
/// upload no message names is believed to be invisible to everyone
/// `[Verify]`, which is what makes this the one write probed without a
/// staged conversation.
///
/// Three rungs, stopping at the first that works, so a working shape costs
/// one upload: purple's shape on the app's endpoints, then without the
/// account segment (`findings.md` §51.2 found the two identical for a fetch),
/// then maugclib's, which adds `alt` and the API key.
///
/// **Statuses, header names, hosts, field numbers and lengths. Never a value**
/// beyond the two upload-protocol words Google answers with
/// (`x-goog-upload-status`, the chunk size), the probe's own file name and
/// type, and its 16×16 size, all of which this probe chose.
public enum UploadProbeReport {
    /// A 16×16 PNG of one colour, 79 bytes, made by hand: nobody's picture.
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGOQz79BEmIY1TCqYfhqAACa"
            + "HWYQlSTCVwAAAABJRU5ErkJggg==")!
    /// Shaped like a default macOS screenshot name, which has a narrow
    /// no-break space (U+202F) before PM, plus an accented letter, so one run
    /// also answers whether a name outside ASCII survives the percent-encoded
    /// `x-goog-upload-file-name` (`AttachmentUpload.headerSafe`) `[Verify]`.
    static let fileName = "Kibble probe café 9.41\u{202F}PM.png"

    /// What every rung shares: the transport and the bootstrapped session.
    struct Session {
        let transport: any HTTPTransport
        let credentials: SessionCredentials
        let xsrfToken: String?
    }

    struct Rung {
        let label: String
        let endpoints: ChatEndpoints
        let includesAPIKey: Bool
    }

    static func rungs(_ endpoints: ChatEndpoints) -> [Rung] {
        let bare = ChatEndpoints(host: endpoints.host, account: .none, userAgent: endpoints.userAgent)
        return [
            Rung(label: "purple's shape, app endpoints", endpoints: endpoints, includesAPIKey: false),
            Rung(label: "purple's shape, no account segment", endpoints: bare, includesAPIKey: false),
            Rung(
                label: "maugclib's shape (alt, key), app endpoints",
                endpoints: endpoints,
                includesAPIKey: true
            )
        ]
    }

    /// Every parameter defaults, so `MacHost` names no core type, the same
    /// shape as `APIProbeReport.run`. The default conversation is the newest
    /// DM, where a run is most easily staged.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        conversation: ProbeConversation = .mostRecentDirectMessage
    ) async -> String {
        var lines = ["gchat upload probe (one upload per rung until one works; no message is posted)", ""]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let bootstrapped = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              )
        else { return lines.joined(separator: "\n") }
        let client = ProtoAPIClient(
            transport: transport, endpoints: endpoints,
            credentials: bootstrapped.credentials, xsrfToken: bootstrapped.wiz.xsrfToken
        )
        guard let group = await chooseGroup(client: client, conversation: conversation, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else {
            lines.append("could not write the probe's PNG to a temporary file")
            return lines.joined(separator: "\n")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let session = Session(
            transport: transport, credentials: bootstrapped.credentials, xsrfToken: bootstrapped.wiz.xsrfToken
        )
        let upload = UploadFile(url: file, name: fileName, contentType: "image/png", byteCount: png.count)
        for rung in rungs(endpoints) {
            let worked = await appendRung(rung, file: upload, group: group, session: session, lines: &lines)
            if worked {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func chooseGroup(
        client: ProtoAPIClient, conversation: ProbeConversation, lines: inout [String]
    ) async -> GroupId? {
        let response: PaginatedWorldResponse
        do {
            response = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
        } catch {
            lines.append("paginated_world FAILED: \(APIProbeReport.safeDescription(of: error))")
            return nil
        }
        let conversations = WorldMapping.map(response).conversations
        lines.append("conversation:")
        guard let index = APIProbeReport.chooseConversationIndex(
            conversations,
            choice: conversation,
            lines: &lines
        ),
            let group = ChannelEventMapping.groupID(for: conversations[index].id)
        else {
            lines.append("  no conversation to upload into")
            return nil
        }
        lines.append(APIProbeReport.conversationKindLine(conversations[index].kind))
        lines.append("")
        return group
    }

    /// One rung's exchanges and outcome; `true` when it uploaded.
    static func appendRung(
        _ rung: Rung,
        file: UploadFile,
        group: GroupId,
        session: Session,
        lines: inout [String]
    ) async -> Bool {
        let recorder = UploadProbeTransport(session.transport)
        let upload = AttachmentUpload(
            transport: recorder, endpoints: rung.endpoints,
            credentials: session.credentials, xsrfToken: session.xsrfToken
        )
        lines.append("rung: \(rung.label)")
        let outcome: Result<UploadMetadata, AttachmentUploadFailure>
        do {
            outcome = try await .success(upload.upload(
                file, group: group, includesAPIKey: rung.includesAPIKey
            ) { _, _ in })
        } catch {
            outcome = .failure(error)
        }
        for exchange in await recorder.exchanges {
            lines.append(contentsOf: exchange.lines)
        }
        switch outcome {
        case let .success(metadata):
            lines.append(contentsOf: metadataLines(metadata))
            lines.append("")
            return true
        case let .failure(failure):
            lines.append("  FAILED: \(failure.reason)")
            if let refusal = failure.refusal {
                lines.append(
                    "    answer: \(refusal.contentType ?? "no content type"), \(refusal.bodyBytes) bytes, "
                        + "headers \(refusal.headerNames.joined(separator: ","))"
                )
            }
            lines.append("")
            return false
        }
    }

    /// The fields the answer carried, by number, and whether the values this
    /// probe chose came back unchanged. The token by length only.
    static func metadataLines(_ metadata: UploadMetadata) -> [String] {
        let bytes: Data = (try? metadata.serializedBytes()) ?? Data()
        let fields = ProtoFieldScan.fields(in: bytes).fields
            .map { "\($0.number)" }
            .joined(separator: " ")
        let dimension = metadata.hasOriginalDimension
            ? "\(metadata.originalDimension.width)x\(metadata.originalDimension.height)"
            : "absent"
        return [
            "  UPLOADED. metadata fields: \(fields)",
            "    attachment token: \(metadata.attachmentToken.count) chars",
            "    content_name echoed: \(metadata.contentName == fileName)"
                + (metadata.contentName == fileName ? "" : " (came back as \(escaped(metadata.contentName)))")
                + ", "
                + "content_type: \(metadata.hasContentType ? metadata.contentType : "absent"), "
                + "original_dimension: \(dimension)"
        ]
    }
}

extension UploadProbeReport {
    /// The probe's own name as it came back, with everything outside
    /// printable ASCII as `\u{…}`, so a percent sign and a U+202F are both
    /// visible. Only ever applied to `content_name`, which this probe chose.
    static func escaped(_ name: String) -> String {
        name.unicodeScalars.map { scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7F
                ? String(scalar) : "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        }.joined()
    }
}

/// The transport each rung goes through, recording what a report may say
/// about every exchange: method, host, path and query **names**, status,
/// response header names, the two upload-protocol words, and the body's size
/// and encoding.
actor UploadProbeTransport: HTTPTransport {
    struct Exchange {
        let lines: [String]
    }

    private let inner: any HTTPTransport
    private(set) var exchanges: [Exchange] = []

    init(_ inner: any HTTPTransport) {
        self.inner = inner
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await recorded(request) { try await inner.send(request) }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await inner.stream(request)
    }

    func upload(
        _ request: HTTPRequest, fromFile file: URL, progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> HTTPResponse {
        try await recorded(request) { try await inner.upload(request, fromFile: file, progress: progress) }
    }

    private func recorded(
        _ request: HTTPRequest, _ perform: () async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        let head = "  \(request.method.rawValue) \(Self.describe(request.url))"
            + " (cookie \(request.headers["Cookie"] == nil ? "no" : "yes"),"
            + " xsrf \(request.headers["x-framework-xsrf-token"] == nil ? "no" : "yes"))"
        do {
            let response = try await perform()
            exchanges.append(Exchange(lines: [head] + Self.describe(response)))
            return response
        } catch let classified as ClassifiedTransportFailure {
            exchanges.append(Exchange(lines: [
                head,
                "    transport failure: \(classified.reason.safeDescription)"
            ]))
            throw classified
        } catch {
            exchanges.append(Exchange(lines: [head, "    transport failure (unclassified)"]))
            throw error
        }
    }

    /// The host, each path segment unless it is long enough to be an id,
    /// and the query's names.
    static func describe(_ url: URL) -> String {
        let segments = url.pathComponents.filter { $0 != "/" }
            .map { $0.count > 24 ? "<\($0.count) chars>" : $0 }
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        return "\(url.host() ?? "?")/\(segments.joined(separator: "/"))"
            + (names.isEmpty ? "" : " ?\(names.joined(separator: ","))")
    }

    static func describe(_ response: HTTPResponse) -> [String] {
        let names = Array(Set(response.headers.fields.map { $0.name.lowercased() })).sorted()
        var lines = ["    \(response.status), headers: \(names.joined(separator: ","))"]
        var protocolWords: [String] = []
        if let status = response.headers["x-goog-upload-status"] {
            protocolWords.append("upload-status \(status.prefix(16))")
        }
        if let granularity = response.headers["x-goog-upload-chunk-granularity"], Int(granularity) != nil {
            protocolWords.append("chunk-granularity \(granularity)")
        }
        if let location = response.headers["x-goog-upload-url"].flatMap(URL.init(string:)) {
            protocolWords.append("upload-url \(describe(location))")
        }
        if !protocolWords.isEmpty {
            lines.append("    \(protocolWords.joined(separator: "; "))")
        }
        let text = String(decoding: response.body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base64 = !response.body.isEmpty && Data(base64Encoded: text) != nil
        let encoding = response.body.isEmpty ? "" : base64 ? ", base64" : ", not base64"
        lines.append("    body \(response.body.count) bytes\(encoding)")
        return lines
    }
}
