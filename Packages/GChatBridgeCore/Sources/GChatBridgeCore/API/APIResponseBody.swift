import Foundation

/// How an `/api/` response body was actually encoded.
///
/// Reported rather than swallowed. §3.6 found the response is raw binary
/// **despite** the `X-Goog-Encode-Response-If-Executable: base64` header, which
/// directly contradicts the reference's comment at `client.py:635`. A client
/// that silently copes with either learns nothing; one that reports which it got
/// turns the next run into a measurement.
public enum APIResponseEncoding: String, Sendable, Hashable {
    case raw
    case base64
}

/// Turning a response body into the protobuf bytes inside it.
///
/// §3.6's instruction is to **accept both** encodings. "Try base64, fall back to
/// raw" is not enough on its own, because a short protobuf can be accidentally
/// valid base64 - so the guess is structural and the other option is always kept
/// as a fallback for the caller to try.
public enum APIResponseBody {
    /// One way of reading the body, and what it would mean.
    public struct Candidate: Sendable, Hashable {
        public let bytes: Data
        public let encoding: APIResponseEncoding
    }

    /// Every reading worth trying, best guess first.
    ///
    /// The caller tries them in order and takes the first that parses. Both are
    /// offered whenever the body *could* be base64, because being wrong about
    /// that must cost a retry rather than the response.
    public static func candidates(_ data: Data) -> [Candidate] {
        guard !data.isEmpty else { return [] }
        guard looksBase64(data), let decoded = Data(base64Encoded: data) else {
            return [Candidate(bytes: data, encoding: .raw)]
        }
        return [
            Candidate(bytes: decoded, encoding: .base64),
            Candidate(bytes: data, encoding: .raw)
        ]
    }

    /// Whether the body is *shaped* like base64: every byte in the alphabet, and
    /// a length that is a multiple of four.
    ///
    /// A structural test rather than a decode attempt, because
    /// `Data(base64Encoded:)` is lenient enough to accept things that were never
    /// base64 - and on this protocol a wrong guess about the encoding surfaces
    /// as an unintelligible decode error pointing at the wrong layer entirely.
    static func looksBase64(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count % 4 == 0 else { return false }
        return data.allSatisfy(isBase64Byte)
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
            true
        default:
            false
        }
    }
}
