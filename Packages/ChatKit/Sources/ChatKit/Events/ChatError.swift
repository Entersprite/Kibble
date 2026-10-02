import Foundation

/// Everything that can go wrong at the seam, in a form that survives the wire.
///
/// A `ChatError` is both a Swift `Error` and a codable frame payload, because
/// the same failure has to be throwable by a local backend and deliverable by a
/// remote one.
public enum ChatError: Error, Codable, Hashable, Sendable {
    /// No credentials at all. A client should send the user to sign in.
    case notAuthenticated

    /// Credentials existed and have stopped working. Distinct from
    /// `notAuthenticated` because the recovery is different: refresh first, and
    /// only then ask the user.
    case sessionExpired

    /// `retryAfter` is `nil` when the backend gave no hint, which is not the
    /// same as zero.
    case rateLimited(retryAfter: Duration?)

    /// A command was sent that `Capabilities` says is not supported. The string
    /// is the capability's name, so `unsupported(capability: "canEditMessages")`
    /// is greppable against the property that would have allowed it.
    case unsupported(capability: String)

    /// The session works, but this action needs a sign-in it predates: a
    /// session stored before cookie domains were kept (`findings.md` §52.9).
    /// A client offers to sign in again; it does not sign the person out.
    case signInRequired(String)

    /// The connection failed: DNS, TLS, a dropped long poll. Retryable in
    /// principle.
    case transport(String)

    /// Something arrived that could not be parsed. Not retryable — the same
    /// bytes will fail again — and worth reporting, because it usually means
    /// the protocol moved.
    case decoding(String)

    /// The server answered, and the answer was a refusal. `status` is the HTTP
    /// status where there is one.
    case server(status: Int, message: String)

    /// Anything else, including an error type from a newer backend that this
    /// build has never heard of.
    case unknown(String)
}

extension ChatError {
    enum CodingKeys: String, CodingKey {
        case type
        case retryAfter
        case capability
        case status
        case message
    }

    enum Tag: String {
        case notAuthenticated
        case sessionExpired
        case rateLimited
        case unsupported
        case signInRequired
        case transport
        case decoding
        case server
        case unknown
    }

    /// An unrecognised error type becomes `.unknown(rawType)` rather than
    /// throwing. That is lossy — the payload of the unfamiliar error is
    /// dropped, unlike `ChatEvent.unknown`, which keeps it verbatim — but an
    /// error frame that fails to decode would replace a useful diagnostic with
    /// a useless one, which is the worst possible trade at exactly the moment
    /// something is already wrong.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let tag = Tag(rawValue: raw) else {
            self = .unknown(raw)
            return
        }
        self = try Self.decode(tag, from: container)
    }

    private static func decode(
        _ tag: Tag,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatError {
        switch tag {
        case .notAuthenticated:
            .notAuthenticated
        case .sessionExpired:
            .sessionExpired
        case .rateLimited:
            try .rateLimited(
                retryAfter: container.decodeWireIfPresent(Duration.self, forKey: .retryAfter)
            )
        case .unsupported:
            try .unsupported(capability: container.decode(String.self, forKey: .capability))
        case .signInRequired:
            try .signInRequired(container.decode(String.self, forKey: .message))
        case .transport:
            try .transport(container.decode(String.self, forKey: .message))
        case .decoding:
            try .decoding(container.decode(String.self, forKey: .message))
        case .server:
            try .server(
                status: container.decode(Int.self, forKey: .status),
                message: container.decode(String.self, forKey: .message)
            )
        case .unknown:
            try .unknown(container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notAuthenticated:
            try container.encode(Tag.notAuthenticated.rawValue, forKey: .type)
        case .sessionExpired:
            try container.encode(Tag.sessionExpired.rawValue, forKey: .type)
        case let .rateLimited(retryAfter):
            try container.encode(Tag.rateLimited.rawValue, forKey: .type)
            try container.encodeWireIfPresent(retryAfter, forKey: .retryAfter)
        case let .unsupported(capability):
            try container.encode(Tag.unsupported.rawValue, forKey: .type)
            try container.encode(capability, forKey: .capability)
        default:
            try encodeRemainder(into: &container)
        }
    }

    private func encodeRemainder(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch self {
        case let .signInRequired(message):
            try container.encode(Tag.signInRequired.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .transport(message):
            try container.encode(Tag.transport.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .decoding(message):
            try container.encode(Tag.decoding.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .server(status, message):
            try container.encode(Tag.server.rawValue, forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode(message, forKey: .message)
        case let .unknown(message):
            try container.encode(Tag.unknown.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        default:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}
