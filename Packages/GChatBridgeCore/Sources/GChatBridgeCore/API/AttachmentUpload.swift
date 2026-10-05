import Foundation
import SwiftProtobuf

/// Why an upload failed. Never carries a URL, a token or the transport's own
/// error, whose description can carry the request's URL.
public struct AttachmentUploadFailure: Error, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The start answered something other than 2xx, a redirect included.
        case startRefused(Int)
        /// A request redirected to Google's sign-in page: the session is not
        /// usable.
        case signInRedirect
        /// A 2xx start with no `x-goog-upload-url`. Auth failure is HTTP 200
        /// on this protocol, so this is how a signed-out session presents
        /// itself here.
        case noUploadURL
        /// The upload address was not `https` on the chat host or a
        /// `google.com` sibling, so the bytes and the session's cookies were
        /// not sent to it.
        case uploadURLRefused
        /// The PUT answered something other than 2xx.
        case uploadRefused(Int)
        /// The PUT's answer was neither base64 nor raw `UploadMetadata`.
        case undecodableMetadata
        /// The metadata carried no attachment token, so no message can name it.
        case noAttachmentToken
        /// Classified by the transport, or `nil` when it could not be.
        case transport(TransportFailureReason?)
    }

    public let reason: Reason
    /// What a refusing answer looked like, without its body or any header
    /// value. Set for the start's refusals and `noUploadURL`.
    public let refusal: AttachmentFetchFailure.Refusal?

    public init(reason: Reason, refusal: AttachmentFetchFailure.Refusal? = nil) {
        self.reason = reason
        self.refusal = refusal
    }
}

/// One file to upload: where it is, the name and type it is sent under, and
/// its size, which the start announces before any byte is sent.
public struct UploadFile: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let contentType: String
    public let byteCount: Int

    public init(url: URL, name: String, contentType: String, byteCount: Int) {
        self.url = url
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

/// Uploads one file, the way both references do, and returns the
/// `UploadMetadata` a message then carries as a type-13 annotation
/// (`SendRequests.uploadAnnotation(_:)`).
///
/// ## The two requests `[Verify]`
///
/// 1. **Start:** `POST /uploads?group_id=<raw id>` with the
///    `x-goog-upload-*` headers and no body (purple
///    `googlechat_conversation.c:1866-1890`, maugclib `client.py:275-298`).
///    The answer's `x-goog-upload-url` names where the bytes go.
/// 2. **Upload:** one `PUT` of the whole file to that address with
///    `upload, finalize` at offset 0. Neither reference chunks: purple reads
///    `x-goog-upload-chunk-granularity` and then ignores it (`:1810-1817`).
///    The answer is the metadata, base64-encoded in both references.
///
/// Neither has been sent by this implementation. `--probe=upload` sends the
/// pair, and nothing else.
///
/// ## Credentials
///
/// The upload address comes out of a response header, and the PUT carries the
/// session's cookies to wherever it names. So it must be `https` on the chat
/// host or a `google.com` sibling, the same label-boundary rule
/// `AttachmentFetch` uses, or nothing is sent at all. Each host is sent only
/// the cookies its domain admits (`findings.md` §52.9), the xsrf token goes to
/// the chat host alone, and neither request follows a redirect.
public struct AttachmentUpload: Sendable {
    static let startTimeout = Duration.seconds(30)
    /// The bytes can be 200 MB on a slow link.
    static let uploadTimeout = Duration.seconds(600)

    let transport: any HTTPTransport
    let endpoints: ChatEndpoints
    private let credentials: SessionCredentials
    private let xsrfToken: String?

    public init(
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        credentials: SessionCredentials,
        xsrfToken: String?
    ) {
        self.transport = transport
        self.endpoints = endpoints
        self.credentials = credentials
        self.xsrfToken = xsrfToken
    }

    /// `includesAPIKey` adds maugclib's `alt=` and `key=` to the start, which
    /// purple does not send. Only the probe asks for it.
    public func upload(
        _ file: UploadFile,
        group: GroupId,
        includesAPIKey: Bool = false,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws(AttachmentUploadFailure) -> UploadMetadata {
        let start = await authorised(startRequest(group: group, file: file, includesAPIKey: includesAPIKey))
        let started = try await exchange(start) { try await transport.send($0) }
        let address = try Self.uploadAddress(from: started, chatHost: endpoints.host)
        let put = await authorised(finalizeRequest(address))
        let transport = transport
        let finished = try await exchange(put) { request in
            try await transport.upload(request, fromFile: file.url, progress: progress)
        }
        return try Self.metadata(from: finished)
    }

    func startRequest(group: GroupId, file: UploadFile, includesAPIKey: Bool) -> HTTPRequest {
        var components = URLComponents(
            url: endpoints.base.appendingPathComponent("uploads"), resolvingAgainstBaseURL: false
        )!
        var items = [("group_id", Self.rawID(group))]
        if includesAPIKey {
            items += [("alt", ""), ("key", APIRequests.defaultAPIKey)]
        }
        components.percentEncodedQuery = QueryEncoding.query(items)
        return HTTPRequest(
            method: .post,
            url: components.url!,
            headers: HTTPHeaders([
                ("x-goog-upload-protocol", "resumable"),
                ("x-goog-upload-command", "start"),
                ("x-goog-upload-content-length", String(file.byteCount)),
                ("x-goog-upload-content-type", file.contentType),
                ("x-goog-upload-file-name", Self.headerSafe(file.name))
            ]),
            timeout: Self.startTimeout,
            traceLabel: "upload_start",
            followsRedirects: false
        )
    }

    func finalizeRequest(_ address: URL) -> HTTPRequest {
        HTTPRequest(
            method: .put,
            url: address,
            headers: HTTPHeaders([
                ("x-goog-upload-command", "upload, finalize"),
                ("x-goog-upload-protocol", "resumable"),
                ("x-goog-upload-offset", "0")
            ]),
            timeout: Self.uploadTimeout,
            traceLabel: "upload_finalize",
            followsRedirects: false
        )
    }

    /// The user agent, the xsrf token on the chat host alone, and the cookies
    /// the URL's own domain admits.
    private func authorised(_ request: HTTPRequest) async -> HTTPRequest {
        var request = request
        var fields = request.headers.fields
        fields.append(.init(name: "User-Agent", value: endpoints.userAgent))
        if request.url.host() == endpoints.host.host(), let xsrfToken {
            fields.append(.init(name: "x-framework-xsrf-token", value: xsrfToken))
        }
        request.headers = HTTPHeaders(fields: fields)
        return await credentials.authorising(request)
    }

    /// One request, with a transport failure classified, and `Set-Cookie`
    /// absorbed only when the request carried a `Cookie` field.
    private func exchange(
        _ request: HTTPRequest,
        _ perform: (HTTPRequest) async throws -> HTTPResponse
    ) async throws(AttachmentUploadFailure) -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await perform(request)
        } catch let classified as ClassifiedTransportFailure {
            throw AttachmentUploadFailure(reason: .transport(classified.reason))
        } catch {
            throw AttachmentUploadFailure(reason: .transport(nil))
        }
        if request.headers["Cookie"] != nil {
            await credentials.absorb(response.headers, from: request.url)
        }
        if response.isRedirect, Self.redirectsToSignIn(response, from: request.url) {
            throw AttachmentUploadFailure(reason: .signInRedirect)
        }
        return response
    }

    static func uploadAddress(
        from response: HTTPResponse, chatHost: URL
    ) throws(AttachmentUploadFailure) -> URL {
        guard (200 ..< 300).contains(response.status) else {
            throw AttachmentUploadFailure(reason: .startRefused(response.status), refusal: refusal(response))
        }
        guard let raw = response.headers["x-goog-upload-url"] else {
            throw AttachmentUploadFailure(reason: .noUploadURL, refusal: refusal(response))
        }
        guard let address = URL(string: raw), isTrusted(address, chatHost: chatHost) else {
            throw AttachmentUploadFailure(reason: .uploadURLRefused)
        }
        return address
    }

    /// `https` on the chat host or a `google.com` sibling, with the label
    /// boundary `CookieScope` insists on: a suffix match without the dot
    /// would admit `evilgoogle.com`.
    static func isTrusted(_ url: URL, chatHost: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == chatHost.host()?.lowercased() || host == "google.com" || host.hasSuffix(".google.com")
    }

    static func metadata(from response: HTTPResponse) throws(AttachmentUploadFailure) -> UploadMetadata {
        guard (200 ..< 300).contains(response.status) else {
            throw AttachmentUploadFailure(reason: .uploadRefused(response.status), refusal: refusal(response))
        }
        guard let metadata = decode(response.body) else {
            throw AttachmentUploadFailure(reason: .undecodableMetadata, refusal: refusal(response))
        }
        guard !metadata.attachmentToken.isEmpty else {
            throw AttachmentUploadFailure(reason: .noAttachmentToken)
        }
        return metadata
    }

    /// Base64 first, as both references decode it, then raw, as every
    /// `/api/` answer actually arrives despite asking for base64
    /// (`findings.md` §3.6). Raw `UploadMetadata` cannot pass for base64: its
    /// first tag is a newline (`0x0A`), which the trim removes, but the
    /// length and tag bytes after it (`0x12`, `0x1A`, `0x22`, and any byte
    /// under `0x20`) are outside the base64 alphabet.
    static func decode(_ body: Data) -> UploadMetadata? {
        let trimmed = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Data(base64Encoded: trimmed),
           let metadata = try? UploadMetadata(serializedBytes: decoded) {
            return metadata
        }
        return try? UploadMetadata(serializedBytes: body)
    }

    private static func redirectsToSignIn(_ response: HTTPResponse, from url: URL) -> Bool {
        guard let location = response.headers["Location"] else { return false }
        return URL(string: location, relativeTo: url)?.absoluteURL.host() == "accounts.google.com"
    }

    private static func refusal(_ response: HTTPResponse) -> AttachmentFetchFailure.Refusal {
        AttachmentFetchFailure.Refusal(
            contentType: response.headers["Content-Type"],
            bodyBytes: response.body.count,
            headerNames: Array(Set(response.headers.fields.map { $0.name.lowercased() })).sorted()
        )
    }

    /// The id both references put in `group_id`: the space's or the DM's own,
    /// with no prefix.
    static func rawID(_ group: GroupId) -> String {
        switch group.id {
        case let .spaceID(space): space.spaceID
        case let .dmID(dm): dm.dmID
        case nil: ""
        }
    }

    /// The name as Google will show it: precomposed (NFC), because macOS
    /// hands out decomposed names and `Ó` would otherwise travel as `O` plus a
    /// combining accent, and with every control character a space, so a
    /// name can never end the header early.
    ///
    /// **Not percent-encoded.** Google stores this header verbatim and never
    /// decodes it: session 50's first probe sent `caf%C3%A9` and got
    /// `caf%C3%A9` back as `content_name`, which every recipient then saw
    /// (`findings.md` §55.4). The text goes as it is, and the transport puts
    /// it on the wire as UTF-8 (`URLSessionTransport.wireValue(_:)`).
    /// Whether Google reads those bytes as UTF-8 is `[Verify]`.
    static func headerSafe(_ name: String) -> String {
        String(String.UnicodeScalarView(
            name.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar
            }
        ))
    }
}
