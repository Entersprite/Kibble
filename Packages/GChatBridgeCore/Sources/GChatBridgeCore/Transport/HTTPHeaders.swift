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

    /// Every `Set-Cookie` value, ready for `CookieJar.absorb(setCookie:from:)`.
    public var setCookies: [String] {
        all("Set-Cookie")
    }
}
