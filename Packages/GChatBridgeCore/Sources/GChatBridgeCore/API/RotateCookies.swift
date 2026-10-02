import Foundation

/// `POST accounts.google.com/RotateCookies`: what Google's own pages call to
/// refresh the `.google.com` `__Secure-1PSIDTS` / `__Secure-3PSIDTS` pair.
///
/// ## Why it exists
///
/// The login capture fires the moment `chat.google.com` first settles, and
/// on 2026-10-02 it held neither cookie for `.google.com` (`findings.md`
/// §52.7). Chat's API works without them, and `chat.usercontent.google.com`
/// refuses every download with an empty 403; whether the two are related is
/// what this call exists to test `[Verify]`.
///
/// ## Where the request comes from
///
/// Not from either reference, which predate the cookie. The method, headers
/// and body are what third-party clients send to recover a session that a
/// scripted login left without the pair (notebooklm-py issue #865)
/// `[Verify]` against Google's own pages. The accounts host is sent what it
/// admits, which for a session captured since §52.9 is the `.google.com`
/// cookies.
///
/// Every `Set-Cookie` it answers is absorbed into `credentials`, but only
/// from a request that actually carried a `Cookie` field - a legacy
/// session's chat-host-only cookies send `accounts.google.com` nothing at
/// all, and absorbing the answer anyway would let a host that was never
/// sent a credential rotate it regardless, the same gate `AttachmentFetch`
/// applies per hop (review fix round 1, Important 1; final review Minor 4).
/// The caller decides whether what *is* absorbed persists by what it hands
/// in.
public struct RotateCookies: Sendable {
    static let url = URL(string: "https://accounts.google.com/RotateCookies")!
    static let body = Data(#"[000,"-0000000000000000000"]"#.utf8)

    /// The status, and the names it set. Never a value.
    public struct Outcome: Sendable, Hashable {
        public let status: Int
        /// In the order the response sent them.
        public let setCookieNames: [String]

        public init(status: Int, setCookieNames: [String]) {
            self.status = status
            self.setCookieNames = setCookieNames
        }
    }

    private let transport: any HTTPTransport
    private let userAgent: String
    private let credentials: SessionCredentials

    public init(transport: any HTTPTransport, userAgent: String, credentials: SessionCredentials) {
        self.transport = transport
        self.userAgent = userAgent
        self.credentials = credentials
    }

    /// Throws only what the transport throws. Any status is an outcome: a
    /// refusal is the answer the caller is asking for.
    public func send() async throws -> Outcome {
        let request = await credentials.authorising(HTTPRequest(
            method: .post,
            url: Self.url,
            headers: HTTPHeaders([
                ("User-Agent", userAgent),
                ("Content-Type", "application/json"),
                ("Origin", "https://accounts.google.com")
            ]),
            body: Self.body,
            timeout: .seconds(30),
            traceLabel: "rotate_cookies",
            followsRedirects: false
        ))
        let response = try await transport.send(request)
        // Gated on the request itself, not mere eligibility: a legacy
        // session sends this host no Cookie field at all, and absorbing its
        // answer regardless would let it rotate a credential it never
        // carried (review fix round 1, Important 1; final review Minor 4).
        if request.headers["Cookie"] != nil {
            await credentials.absorb(response.headers, from: Self.url)
        }
        return Outcome(
            status: response.status,
            setCookieNames: response.headers.setCookies.map { value in
                String(value.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces)
            }
        )
    }
}
