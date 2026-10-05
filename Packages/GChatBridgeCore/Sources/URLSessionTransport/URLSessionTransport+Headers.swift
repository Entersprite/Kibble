import Foundation

extension URLSessionTransport {
    /// A header value as its UTF-8 bytes on the wire.
    ///
    /// **Measured, session 50:** `URLRequest` writes a header value as
    /// Latin-1 and silently **cuts it at the first character Latin-1 cannot
    /// hold**. `café 9.41<U+202F>PM.pdf` reached a local listener as
    /// `café 9.41`, the `é` as one byte. So a value outside ASCII is handed
    /// over as one character per UTF-8 byte, which the Latin-1 step writes
    /// back as exactly those bytes - what a browser sends for a header it
    /// was given as a byte string. ASCII is unchanged, which is every header
    /// but an upload's file name.
    static func wireValue(_ value: String) -> String {
        guard !value.utf8.allSatisfy({ $0 < 0x80 }) else { return value }
        return String(decoding: value.utf8.map { UInt16($0) }, as: UTF16.self)
    }
}
