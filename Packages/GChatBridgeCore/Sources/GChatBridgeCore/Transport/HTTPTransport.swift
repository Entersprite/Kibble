import Foundation

/// An ordered list of header fields, with repeated names preserved.
///
/// **Not a dictionary, deliberately.** `Set-Cookie` legitimately appears many
/// times in one response — an observed long-poll reopen rotated three cookies at
/// once — and a `[String: String]` would keep one and silently discard the rest.
/// The symptom would not be a parse error; it would be a session that expires
/// for no visible reason some minutes later.
///
/// Lookup is case-insensitive because HTTP field names are, and servers are
/// inconsistent in practice: matching exactly is the kind of bug that passes
/// every test and fails on the wire.
public struct HTTPHeaders: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let fields: [Field]

    /// Labelled, so that `HTTPHeaders([])` is unambiguously the pair form below
    /// rather than an empty list of `Field`s.
    public init(fields: [Field]) {
        self.fields = fields
    }

    /// The form call sites use: pairs, reading as they would in a capture.
    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }

    /// Every value for `name`, in the order the server sent them.
    public func all(_ name: String) -> [String] {
        let wanted = name.lowercased()
        return fields.filter { $0.name.lowercased() == wanted }.map(\.value)
    }

    /// The first value for `name`, which is what single-valued fields want.
    public subscript(name: String) -> String? {
        all(name).first
    }

    /// Every `Set-Cookie` value, ready for `CookieJar.absorb(setCookie:)`.
    public var setCookies: [String] {
        all("Set-Cookie")
    }
}

// MARK: - Request

/// A request, expressed without Foundation's networking types.
///
/// Those types are avoided here on purpose: on Linux they resolve from
/// `FoundationNetworking` rather than `Foundation`, so using one would break the
/// rule that lets a future bridge server link this package verbatim. The exact
/// names are listed in the portability scan in `scripts/test.sh`, which greps
/// this target for them and fails the build — deliberately not repeated here,
/// since that scan does not exempt comments and is the authoritative list.
public struct HTTPRequest: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?

    /// Long polls hold a response open for a minute or more, so the default is
    /// generous and callers shorten it rather than lengthen it.
    public var timeout: Duration

    public init(
        method: Method = .get,
        url: URL,
        headers: HTTPHeaders = HTTPHeaders([]),
        body: Data? = nil,
        timeout: Duration = .seconds(70)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

// MARK: - Response

/// A completed response.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Deliberately absent: any notion of "was this successful". On this protocol
    /// **an auth failure is HTTP 200** carrying the sign-in shell, so a
    /// `isSuccess` here would be an invitation to trust the wrong signal. Use
    /// `WizGlobalData`.
    public var isRedirect: Bool {
        (300 ..< 400).contains(status)
    }
}

/// A response whose head has arrived and whose body is still being delivered.
///
/// The long poll needs this shape rather than a completed `HTTPResponse`: the
/// channel's SID arrives in the **`X-HTTP-Initial-Response` header** of a
/// response whose body then stays open for the duration of the poll. A transport
/// that only returns completed responses could not surrender the SID until the
/// poll ended, by which time it is useless.
public struct HTTPStream: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: AsyncThrowingStream<Data, any Error>

    public init(
        status: Int,
        headers: HTTPHeaders,
        body: AsyncThrowingStream<Data, any Error>
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

// MARK: - The seam

/// The one thing this package needs from the network, and the reason the rest of
/// it is pure.
///
/// Everything above this protocol — framing, the channel state machine,
/// catch-up, auth detection — is testable with no network, no Keychain and no
/// Google account. Only `URLSessionTransport` implements it against a real
/// socket, which bounds the Linux port to a single file by construction.
public protocol HTTPTransport: Sendable {
    /// A request whose body is read to completion.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// A request whose body is delivered incrementally, for the long poll.
    ///
    /// Chunks are handed over exactly as they arrive off the socket. Framing is
    /// the caller's job, because chunk boundaries are not message boundaries —
    /// a frame can be split across two reads.
    func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

// MARK: - Recovering collapsed headers

public extension HTTPHeaders {
    /// Builds headers from the collapsed dictionary Foundation hands back, and
    /// **restores the repeated `Set-Cookie` fields it destroyed.**
    ///
    /// This is measured behaviour, not a precaution. A server returning three
    /// `Set-Cookie` headers, read back through Foundation's HTTP client, arrives
    /// as a single field:
    ///
    /// ```
    /// SIDCC=aaa; Path=/; Secure, COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/,
    /// __Secure-1PSIDCC=bbb; Secure; HttpOnly
    /// ```
    ///
    /// So a transport that trusted the dictionary would see one cookie where the
    /// server sent three — and on this protocol that is a lost credential, which
    /// surfaces minutes later as an unexplained expiry.
    ///
    /// Splitting lives here, in the portable core, rather than in the transport:
    /// it is pure string work, it is where the tests can reach it without a
    /// socket, and any HTTP client that collapses headers has the same problem.
    init(collapsed fields: [String: String]) {
        var expanded: [Field] = []
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            if name.lowercased() == "set-cookie" {
                expanded += Self.splitSetCookie(value).map { Field(name: name, value: $0) }
            } else {
                expanded.append(Field(name: name, value: value))
            }
        }
        self.init(fields: expanded)
    }

    /// Splits a comma-joined `Set-Cookie` value back into individual cookies.
    ///
    /// **A comma is only a boundary when what follows starts a new cookie**,
    /// which means a name then `=`. That test is what keeps
    /// `Expires=Thu, 01 Jan 1970 00:00:00 GMT` in one piece: after its comma
    /// comes `01 Jan 1970 00:00:00 GMT`, which reaches `;` or the end without an
    /// `=`. A cookie name also cannot contain whitespace, so a date fragment
    /// cannot masquerade as one even if an `=` appears later inside it.
    ///
    /// Getting this wrong in the obvious way — splitting on every comma — turns
    /// a deletion into two malformed fragments, and a deletion misread as a live
    /// cookie means replaying a credential the server has just retired.
    internal static func splitSetCookie(_ joined: String) -> [String] {
        var cookies: [String] = []
        var current = ""

        for piece in joined.split(separator: ",", omittingEmptySubsequences: false) {
            if current.isEmpty {
                current = String(piece)
            } else if startsNewCookie(piece) {
                cookies.append(current.trimmingCharacters(in: .whitespaces))
                current = String(piece)
            } else {
                // The comma belonged to the previous cookie - almost always the
                // day-of-week comma in an Expires date. Put it back.
                current += "," + piece
            }
        }
        if !current.isEmpty {
            cookies.append(current.trimmingCharacters(in: .whitespaces))
        }
        return cookies.filter { !$0.isEmpty }
    }

    /// Whether a fragment following a comma begins a new cookie: a non-empty
    /// name with no whitespace, terminated by `=`.
    private static func startsNewCookie(_ piece: some StringProtocol) -> Bool {
        let candidate = piece.drop { $0 == " " || $0 == "\t" }
        var name = ""
        for character in candidate {
            if character == "=" {
                return !name.isEmpty
            }
            if character == ";" || character.isWhitespace {
                return false
            }
            name.append(character)
        }
        return false // reached the end without an '=' - not a cookie
    }
}
