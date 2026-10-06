import Foundation
import GChatBridgeCore

/// What `list_topics` pages carry in the way of uploaded attachments - counts,
/// MIME types and field numbers only. Never a token, a filename or a URL: the
/// report is pasted into `findings.md`. No probe run had ever seen an
/// `UPLOAD_METADATA` annotation before this section (`findings.md` §40-§41
/// saw types 6, 8 and 12 only), so every wire fact the inline-images slice
/// rests on waits on it.
struct AttachmentShapes: Equatable {
    var messages = 0
    var withUploads = 0
    /// Annotations whose metadata oneof is `upload_metadata`.
    var uploads = 0
    /// MIME type → count. A value not shaped like a MIME type is keyed by
    /// `unusualContentTypeKey(_:)` instead, because a field that should hold
    /// `image/png` and holds something else might hold anything.
    var contentTypes: [String: Int] = [:]
    /// Attachment token length in UTF-8 bytes → count. Never the token.
    var tokenLengths: [Int: Int] = [:]
    var namesPresent = 0
    /// Top-level field numbers inside each `UploadMetadata`, as a byte walk
    /// sees them → how many uploads carried one. Field 5
    /// (`original_dimension`) is commented out of the vendored proto, so only
    /// the walk can see it (`CLAUDE.md`: believe the walk).
    var metadataFields: [Int: Int] = [:]
    /// Field 5's width and height, where it decodes, in encounter order.
    var dimensions: [UploadDimensionShape] = []
    /// The first upload whose MIME type starts `image/`: the one the fetch
    /// section asks for. Held, never printed.
    var firstImage: ProbedUpload?
    /// The first upload that is not an image: the one the download section
    /// asks for. Held, never printed.
    var firstFile: ProbedUpload?
}

struct UploadDimensionShape: Equatable {
    var width: UInt64
    var height: UInt64
}

/// What a fetch needs from an upload. Equatable for tests; the token never
/// reaches a report line.
struct ProbedUpload: Equatable {
    var token: String
    var contentType: String
}

/// The probe's attachment sections. Split into their own file for the same
/// `file_length` reason `APIProbeReport+Mentions.swift` is, and pure apart
/// from `appendAttachmentSections`, so `AttachmentProbeTests` covers every
/// line against invented messages.
extension APIProbeReport {
    private static let dimensionField = 5
    private static let maxRenderedDimensions = 5

    /// Hosts printed in full. Any other host is reduced to its last two
    /// labels, since a label could in principle carry an identifier and no
    /// capture has shown what this chain's hosts look like.
    private static let knownHosts: Set = [
        "chat.google.com", "accounts.google.com", "mail.google.com",
        "lh3.googleusercontent.com", "lh4.googleusercontent.com",
        "lh5.googleusercontent.com", "lh6.googleusercontent.com"
    ]

    static func attachmentShapes(_ messages: [GChatBridgeCore.Message]) -> AttachmentShapes {
        var shapes = AttachmentShapes()
        for message in messages {
            shapes.messages += 1
            var sawUpload = false
            for annotation in message.annotations {
                guard case let .uploadMetadata(metadata)? = annotation.metadata else { continue }
                sawUpload = true
                count(metadata, into: &shapes)
            }
            if sawUpload {
                shapes.withUploads += 1
            }
        }
        return shapes
    }

    private static func count(_ metadata: UploadMetadata, into shapes: inout AttachmentShapes) {
        shapes.uploads += 1
        shapes.contentTypes[contentTypeKey(metadata.contentType), default: 0] += 1
        shapes.tokenLengths[metadata.attachmentToken.utf8.count, default: 0] += 1
        if metadata.hasContentName {
            shapes.namesPresent += 1
        }
        let bytes: Data = (try? metadata.serializedBytes()) ?? Data()
        for number in Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number)) {
            shapes.metadataFields[number, default: 0] += 1
        }
        for payload in ProtoFieldScan.payloads(ofField: dimensionField, in: bytes) {
            if let width = ProtoFieldScan.varintValues(ofField: 1, in: payload).first,
               let height = ProtoFieldScan.varintValues(ofField: 2, in: payload).first {
                shapes.dimensions.append(UploadDimensionShape(width: width, height: height))
            }
        }
        let upload = ProbedUpload(token: metadata.attachmentToken, contentType: metadata.contentType)
        if metadata.contentType.hasPrefix("image/") {
            shapes.firstImage = shapes.firstImage ?? upload
        } else {
            shapes.firstFile = shapes.firstFile ?? upload
        }
    }

    /// The type itself, optionally with one `charset` parameter (§52.3 met
    /// `application/json; charset=utf-8`). Any other parameter is a value
    /// nothing has shown the shape of, so the whole type becomes a length.
    static func contentTypeKey(_ type: String) -> String {
        let pattern = #"^[a-z]+/[a-z0-9.+-]{1,40}(; ?charset=[A-Za-z0-9-]{1,20})?$"#
        let shaped = type.range(of: pattern, options: .regularExpression) != nil
        return shaped ? type : "(unusual, \(type.count) chars)"
    }

    static func attachmentShapesLines(_ shapes: AttachmentShapes) -> [String] {
        let types = shapes.contentTypes.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        let lengths = shapes.tokenLengths.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        let fields = shapes.metadataFields.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        var dimensions = shapes.dimensions.prefix(maxRenderedDimensions).map { "\($0.width)×\($0.height)" }
        if shapes.dimensions.count > maxRenderedDimensions {
            dimensions.append("…")
        }
        return [
            "  messages with uploads: \(shapes.withUploads)/\(shapes.messages), uploads: \(shapes.uploads)",
            "  content types: \(joined(types))",
            "  token lengths: \(joined(lengths)); names present: \(shapes.namesPresent)/\(shapes.uploads)",
            "  upload metadata fields: \(joined(fields))",
            "  dimensions: \(joined(dimensions))"
        ]
    }

    private static func joined(_ parts: [String]) -> String {
        parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    // MARK: - The fetch

    static func attachmentFetchLines(
        label: String,
        outcome: Result<FetchedAttachment, AttachmentFetchFailure>
    ) -> [String] {
        hopLines(label: label, outcome: outcome) { fetched in
            "content type \(fetched.contentType.map(contentTypeKey) ?? "none"), "
                + "\(fetched.body.count) bytes, format \(imageFormat(fetched.body))"
        }
    }

    /// A file's download. `Content-Disposition` carries the file's name, so
    /// it and its `filename=` are reported by presence only.
    static func attachmentDownloadLines(
        label: String,
        outcome: Result<FetchedAttachment, AttachmentFetchFailure>
    ) -> [String] {
        hopLines(label: label, outcome: outcome) { fetched in
            let disposition = fetched.contentDisposition
            let hasFilename = disposition?.lowercased().contains("filename") == true
            return "content type \(fetched.contentType.map(contentTypeKey) ?? "none"), "
                + "\(fetched.body.count) bytes; "
                + "Content-Disposition \(disposition == nil ? "absent" : "present"), "
                + "filename \(hasFilename ? "present" : "absent"), format \(fileFormat(fetched.body))"
        } + addressAndRefusalLines(outcome)
    }

    static func hopLines(
        label: String,
        outcome: Result<FetchedAttachment, AttachmentFetchFailure>,
        success: (FetchedAttachment) -> String
    ) -> [String] {
        let hops: [AttachmentHop]
        let detail: String
        switch outcome {
        case let .success(fetched):
            hops = fetched.hops
            detail = success(fetched)
        case let .failure(failure):
            hops = failure.hops
            detail = "FAILED: \(describe(failure.reason))"
        }
        let chain = hops.map { hop in
            "\(renderHost(hop.host)) \(hop.status)\(hop.carriedCredentials ? " (credentials)" : "")"
        }
        return [
            "  \(label): \(chain.isEmpty ? "no hop completed" : chain.joined(separator: " → "))",
            "    \(detail)"
        ]
    }

    /// In full when it is a known host, or a host under Google's own domains
    /// made only of plain lowercase words (`chat.usercontent.google.com`):
    /// that names a service. Anything else - digits, hyphens, another domain -
    /// is reduced to its last two labels, since a label like
    /// `doc-0s-…-docs` can carry an identifier.
    static func renderHost(_ host: String) -> String {
        guard !knownHosts.contains(host), !isPlainGoogleHost(host) else { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let extra = labels.count - 2
        return "\(labels.suffix(2).joined(separator: ".")) (+\(extra) label\(extra == 1 ? "" : "s"))"
    }

    private static func isPlainGoogleHost(_ host: String) -> Bool {
        guard host.hasSuffix(".google.com") || host.hasSuffix(".googleusercontent.com") else { return false }
        return host.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter }
        }
    }

    private static func describe(_ reason: AttachmentFetchFailure.Reason) -> String {
        switch reason {
        case .signInRedirect: "redirected to sign-in"
        case .tooManyRedirects: "more than \(AttachmentFetch.maxHops) hops"
        case .redirectWithoutLocation: "a redirect with no Location"
        case let .httpStatus(status): "HTTP \(status)"
        case .htmlInsteadOfAttachment: "an HTML page instead of the attachment"
        case let .transport(reason): "transport: \(reason?.safeDescription ?? "unclassified")"
        case let .truncated(expected, received): "ended early, \(received) of \(expected) bytes"
        }
    }

    /// The file's kind from its first bytes - PDF, ZIP, or a picture's format -
    /// so a run can say the download is the file, not only that it arrived.
    static func fileFormat(_ data: Data) -> String {
        if data.starts(with: Array("%PDF".utf8)) {
            return "PDF"
        }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "ZIP"
        }
        return imageFormat(data)
    }

    /// The format a body's first bytes name. Read rather than trusted from
    /// `Content-Type`, because a page served as an image would otherwise
    /// count as a success.
    static func imageFormat(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset ..< offset + prefix.count]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) {
            return "PNG"
        }
        if starts([0xFF, 0xD8, 0xFF]) {
            return "JPEG"
        }
        if starts(Array("GIF8".utf8)) {
            return "GIF"
        }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) {
            return "WebP"
        }
        if starts(Array("ftyp".utf8), at: 4) {
            return "HEIF"
        }
        return "unrecognised"
    }

    /// Both sections, against the conversation the topics ladder probed. One
    /// more `list_topics` call on the minimum-viable rung, the same convention
    /// `appendMentionShapesSection` follows. The fetch runs through
    /// `AttachmentFetch` itself - the code the app will use, not a copy - once
    /// per entry in `fetches`, so one run can compare the account-indexed
    /// path with the bare one both references use.
    static func appendAttachmentSections(
        client: ProtoAPIClient,
        group: GroupId,
        fetches: [(label: String, fetch: AttachmentFetch)],
        rotation: RotationRung,
        lines: inout [String]
    ) async {
        lines.append("attachment shapes (counts only):")
        let response: ListTopicsResponse
        do {
            response = try await client.call(
                .listTopics,
                TopicsRequestLadder.minimumViable(for: group).request
            )
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        let shapes = attachmentShapes(response.topics.flatMap(\.replies))
        lines.append(contentsOf: attachmentShapesLines(shapes))
        lines.append("")
        lines.append("attachment fetch (preview, first image upload):")
        if let upload = shapes.firstImage {
            for (label, fetch) in fetches {
                let outcome = await outcome(of: fetch, upload, .preview)
                lines.append(contentsOf: attachmentFetchLines(label: label, outcome: outcome))
            }
        } else {
            lines.append("  no image upload on this page - post one in this conversation and rerun")
        }
        lines.append("")
        lines.append("attachment download (file, first non-image upload):")
        if let upload = shapes.firstFile {
            for (label, fetch) in fetches {
                let outcome = await outcome(of: fetch, upload, .file)
                lines.append(contentsOf: attachmentDownloadLines(label: label, outcome: outcome))
            }
        } else {
            lines.append("  no file upload on this page - post one in this conversation and rerun")
        }
        lines.append("")
        await appendDownloadLadderSection(
            upload: shapes.firstFile,
            fetch: fetches.first?.fetch,
            lines: &lines
        )
        lines.append("")
        await appendRotatedDownloadSection(upload: shapes.firstFile, rung: rotation, lines: &lines)
        lines.append("")
        await appendProjectorConfigSection(upload: shapes.firstFile, fetches: fetches, lines: &lines)
        lines.append("")
        await appendReactionSections(client: client, group: group, fetch: fetches.first?.fetch, lines: &lines)
        await appendMemberListSection(client: client, group: group, lines: &lines)
    }

    private static func outcome(
        of fetch: AttachmentFetch,
        _ upload: ProbedUpload,
        _ variant: AttachmentVariant
    ) async -> Result<FetchedAttachment, AttachmentFetchFailure> {
        do {
            return try await .success(fetch.fetch(
                token: upload.token, contentType: upload.contentType, variant: variant
            ))
        } catch {
            return .failure(error)
        }
    }

    /// The app's own endpoints first, then - when they carry an account
    /// segment - the bare path both references use, so one run says which
    /// shape `get_attachment_url` answers (`findings.md`, the inline-images
    /// probe). Both share the bootstrap's credentials, so a rotation either
    /// one absorbs is the other's too.
    static func attachmentFetches(
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        bootstrapped: (wiz: WizGlobalData, credentials: SessionCredentials)
    ) -> [(label: String, fetch: AttachmentFetch)] {
        func fetch(_ endpoints: ChatEndpoints) -> AttachmentFetch {
            AttachmentFetch(
                transport: transport,
                endpoints: endpoints,
                credentials: bootstrapped.credentials,
                xsrfToken: bootstrapped.wiz.xsrfToken
            )
        }
        var fetches = [(label: "app endpoints (\(endpoints.base.path()))", fetch: fetch(endpoints))]
        if endpoints.account != .none {
            let bare = ChatEndpoints(host: endpoints.host, account: .none, userAgent: endpoints.userAgent)
            fetches.append((label: "no account segment", fetch: fetch(bare)))
        }
        return fetches
    }
}
