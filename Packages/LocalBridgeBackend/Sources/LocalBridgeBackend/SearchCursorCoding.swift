import ChatKit
import Foundation

/// `MessageSearchCursor`'s opaque encoding: this backend's own, never
/// Google's - `SBNmJb`'s own page token is one piece of it, not the whole
/// thing.
///
/// A page 2 request has to resend page 1's query id and every filter
/// (§65.2: "the same on every page of one query"), and `searchMessages(_:
/// after:)` is a single, stateless method with no call carrying context from
/// the one before it - unlike `SearchProbeReport`'s `SearchCallContext`,
/// which lives only for the length of one probe run. So the cursor this
/// backend hands back has to carry everything the next page needs to tell a
/// query it belongs to apart from any other: the query id, Google's own page
/// token, and a fingerprint of the query - the mismatch `searchMessages`
/// refuses rather than silently mixing two searches' filters.
///
/// **A fingerprint, never the decoded `MessageSearchQuery` itself.**
/// `MessageSearchQuery.olderThan` goes on the wire as RFC 3339 with
/// millisecond precision (`WireCoding.swift`), so decoding a stored query
/// back into a `Date` and comparing it against the caller's own
/// sub-millisecond `Date` (built from `.now`) fails equality on every call
/// that sets "Older than" - reproduced 20 of 20 times by a reviewer before
/// this was fixed. Comparing two *encodings* instead sidesteps the problem
/// entirely: `fingerprint(of:)` is called once when a page is handed back and
/// once when the next page is checked, and the same lossy, deterministic
/// encoding applied both times to the same `Date` value produces the same
/// string either way - no `Date` is ever decoded back out of a cursor, so
/// there is nothing left to lose precision on. The wire payload itself still
/// comes from the caller's own `query` (`searchPayload(for:page:)`), never
/// from a cursor's stored copy, so a page's µs bound is always
/// byte-identical to the one before it.
struct SearchCursorPayload: Codable, Hashable {
    let queryID: String
    let pageToken: String
    let queryFingerprint: String
}

enum SearchCursorCoding {
    /// A canonical encoding of `query`, for telling two pages of the same
    /// search apart from two different searches without ever decoding a
    /// `Date` back out of a cursor (see `SearchCursorPayload`'s doc comment).
    /// `.sortedKeys` is a cheap safety net on top of `MessageSearchQuery`'s
    /// own hand-written, fixed field order - either way, the same `query`
    /// value always encodes to the same string.
    static func fingerprint(of query: MessageSearchQuery) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(query) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes `payload` as base64url JSON, matching `MessageSearchCursor`'s
    /// own doc comment ("Opaque, like `Message.ID`"). `/` and `+` never
    /// survive into a value a client might someday log or put in a URL by
    /// accident, and the padding is dropped because nothing here needs it
    /// back - `decode(_:)` restores it before handing the string to
    /// `Data(base64Encoded:)`.
    static func encode(_ payload: SearchCursorPayload) -> MessageSearchCursor {
        guard let data = try? JSONEncoder().encode(payload) else {
            // Unreachable in practice - `SearchCursorPayload` is three plain
            // Codable fields - but a cursor that cannot be decoded later is
            // the one failure mode `decode(_:)` already handles, so a
            // same-shaped `nil` round-trips through the same refusal rather
            // than crashing here.
            return MessageSearchCursor("")
        }
        return MessageSearchCursor(base64URLString(data))
    }

    /// `nil` for a cursor from a build that never produced one of these, or
    /// one that has been altered - `searchMessages(_:after:)` turns either
    /// into `ChatError.unknown` rather than guessing at a page token.
    static func decode(_ cursor: MessageSearchCursor) -> SearchCursorPayload? {
        guard let data = data(fromBase64URLString: cursor.rawValue) else { return nil }
        return try? JSONDecoder().decode(SearchCursorPayload.self, from: data)
    }

    private static func base64URLString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func data(fromBase64URLString string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }
}
