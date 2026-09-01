import Foundation

/// Builds query strings, encoding everything outside the unreserved set.
///
/// Shared by every request this package makes, rather than reimplemented per
/// endpoint, because the encoding is part of what the server accepts and two
/// copies would eventually disagree about one character.
///
/// `URLComponents` is deliberately not trusted with this. It leaves `:`, `/`
/// and `,` unescaped in query values — legal per RFC 3986, and *not* what the
/// reference implementation sends: its `urlencode` produces
/// `origin=https%3A%2F%2Fmail.google.com` and `%2C` for every comma.
///
/// The encoded form is the only one observed to work against the live server;
/// the relaxed form is untested there. On a protocol where `$req` turns out to
/// need **double** percent-encoding, guessing that a laxer encoding is
/// equivalent is not a risk worth taking for tidier code — and matching
/// byte-for-byte keeps a request diffable against a capture, which is the only
/// debugging tool available here.
enum QueryEncoding {
    /// Encodes pairs in the order given. Order is preserved because a request
    /// that differs only in parameter order is harder to diff against a
    /// capture, and the captures are the specification.
    static func query(_ items: [(String, String)]) -> String {
        items
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set.
    ///
    /// Applied to keys as well as values: `$req` goes on the wire as `%24req`,
    /// which is what the probe that passed actually sent.
    static func encode(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
