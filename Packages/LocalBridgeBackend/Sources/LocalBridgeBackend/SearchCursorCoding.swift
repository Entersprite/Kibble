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
/// backend hands back has to carry everything the next page needs to rebuild
/// an identical request: the query id, Google's own page token, and the
/// query itself, so a cursor built for one query can be told apart from one
/// built for another - the mismatch `searchMessages` refuses rather than
/// silently mixing two searches' filters.
struct SearchCursorPayload: Codable, Hashable {
    let queryID: String
    let pageToken: String
    let query: MessageSearchQuery
}

enum SearchCursorCoding {
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
