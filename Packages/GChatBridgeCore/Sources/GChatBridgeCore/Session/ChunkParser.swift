import Foundation

/// Why a chunk stream could not be framed.
///
/// All three mean the same thing operationally — the stream is not what this
/// code understands and continuing would desynchronise it — but they are kept
/// apart because the first is a protocol change and the others are a broken or
/// hostile peer.
public enum ChunkParserError: Error, Hashable, CustomStringConvertible {
    /// The bytes before the first newline were not a length.
    case malformedLengthPrefix(String)

    /// A length was declared that this client will not wait for.
    case declaredLengthTooLarge(String)

    public var description: String {
        switch self {
        case let .malformedLengthPrefix(prefix):
            "the chunk length prefix was not a number: \(prefix.debugDescription)"
        case let .declaredLengthTooLarge(length):
            "a chunk declared a length of \(length), which exceeds the limit"
        }
    }
}

/// Reassembles the long-poll response body into discrete chunks.
///
/// The body is a sequence of `<length>\n<payload>` frames streamed to the
/// client, and the socket splits it wherever it likes: one read may carry
/// several chunks, a fragment of one, or a fragment of a single character.
///
/// ## The length counts UTF-16 code units
///
/// Not bytes, and not characters. The number is JavaScript's `String.length`,
/// which counts UTF-16 code units, so a non-BMP character — an emoji — counts
/// **two**. The reference implementation emulates this by re-encoding the whole
/// buffer to UTF-16 and doubling the declared length; Swift has a UTF-16 view,
/// so the same rule is expressed directly.
///
/// This distinction was **never exercised by live traffic** (`findings.md` §4):
/// no captured chunk contained a non-BMP character, and on pure-BMP text all
/// three interpretations agree. Getting it wrong desynchronises the stream from
/// the first emoji onwards, and the symptom is not a parse error — it is
/// plausible-looking chunks with the wrong boundaries. The offline tests carry
/// the case that live data could not.
///
/// ## Decoding is incremental, deliberately
///
/// A read can end in the middle of a multi-byte UTF-8 sequence. Decoding that
/// eagerly replaces the fragment with U+FFFD and corrupts the payload one
/// character wide — which is small enough that everything downstream still
/// parses, and therefore the worst possible size. The undecodable tail is held
/// back until the rest of it arrives.
public struct ChunkParser: Sendable {
    /// The largest chunk this will wait for, in UTF-16 code units.
    ///
    /// Waiting is the right answer for a chunk still arriving and the wrong one
    /// for a length that will never be satisfied; without a bound the two are
    /// the same code path and the second grows the buffer until the process
    /// dies. 32 Mi code units is far above anything this protocol sends and far
    /// below anything that matters.
    public static let maximumChunkLength = 32 * 1024 * 1024

    /// Undecoded UTF-8 bytes, exactly as they arrived.
    ///
    /// The buffer stays in the wire's encoding rather than as text: consuming a
    /// chunk has to drop a precise number of *bytes*, and a `String` cannot say
    /// how many bytes it came from once a partial sequence is involved.
    private var buffer: [UInt8] = []

    public init() {}

    /// How much is still waiting for the rest of itself. Bytes, not characters.
    public var bufferedByteCount: Int {
        buffer.count
    }

    /// Appends a raw read and returns every chunk it completed.
    ///
    /// Returns an empty array for a read that completes nothing, which is
    /// ordinary rather than exceptional — the handshake's first chunk routinely
    /// spans several reads.
    public mutating func chunks(from newBytes: some Sequence<UInt8>) throws -> [String] {
        buffer.append(contentsOf: newBytes)
        var completed: [String] = []
        while let chunk = try nextChunk() {
            completed.append(chunk)
        }
        return completed
    }

    private mutating func nextChunk() throws -> String? {
        let decodable = Self.completeUTF8Prefix(of: buffer)
        guard decodable > 0 else { return nil }
        let text = String(decoding: buffer[0 ..< decodable], as: UTF8.self)

        // No newline yet means the length itself is still arriving.
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let digits = text[text.startIndex ..< newline]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ChunkParserError.malformedLengthPrefix(String(digits))
        }
        guard let length = Int(digits), length <= Self.maximumChunkLength else {
            throw ChunkParserError.declaredLengthTooLarge(String(digits))
        }

        // The prefix is ASCII digits plus a newline, so its UTF-16 length is
        // its character count. The payload's is the declared number.
        let units = Array(text.utf16)
        let prefixLength = digits.count + 1
        guard units.count - prefixLength >= length else { return nil }

        let payload = String(decoding: units[prefixLength ..< prefixLength + length], as: UTF16.self)
        // Dropped in UTF-8 terms because that is what the buffer holds. Derived
        // from the decoded text rather than from the declared length, which is
        // in different units and would be wrong for anything non-ASCII.
        buffer.removeFirst(String(digits).utf8.count + 1 + payload.utf8.count)
        return payload
    }

    /// How many leading bytes form complete UTF-8 sequences.
    ///
    /// Only the tail can be incomplete, and a UTF-8 sequence is at most four
    /// bytes, so this walks back at most four looking for the lead byte and asks
    /// whether its sequence finished. Anything that is not valid UTF-8 at all is
    /// handed on whole, for the decoder to render as replacement characters —
    /// that is a corrupt stream rather than an incomplete one, and holding bytes
    /// back would stall instead of surfacing it.
    static func completeUTF8Prefix(of bytes: [UInt8]) -> Int {
        var index = bytes.count
        var seen = 0
        while index > 0, seen < 4 {
            index -= 1
            seen += 1
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continue // a continuation byte; the lead is further back
            }
            let needed: Int
            switch byte {
            case 0x00 ... 0x7F: needed = 1
            case 0xC0 ... 0xDF: needed = 2
            case 0xE0 ... 0xEF: needed = 3
            case 0xF0 ... 0xF7: needed = 4
            default: return bytes.count // not a lead byte: corrupt, not partial
            }
            return seen >= needed ? bytes.count : index
        }
        return bytes.count
    }
}
