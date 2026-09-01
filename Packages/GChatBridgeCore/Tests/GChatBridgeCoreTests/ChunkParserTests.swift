import Foundation
import Testing
@testable import GChatBridgeCore

/// Reassembling the long-poll body into chunks.
///
/// The stream arrives as arbitrary byte reads, and a chunk may be split across
/// several of them or several chunks may arrive in one. `findings.md` §4 records
/// the framing as verified against live traffic with zero characters left
/// unframed — and records one thing live traffic could *not* verify, which §4
/// says the offline tests have to carry instead. That case is below.
struct ChunkParserTests {
    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // MARK: - The ordinary shapes

    @Test func oneCompleteChunkYieldsItsPayload() throws {
        var parser = ChunkParser()
        #expect(try parser.chunks(from: bytes("5\n[[0]]")) == ["[[0]]"])
    }

    @Test func twoChunksInOneReadYieldBoth() throws {
        var parser = ChunkParser()
        let read = bytes("5\n[[0]]") + bytes("5\n[[1]]")
        #expect(try parser.chunks(from: read) == ["[[0]]", "[[1]]"])
    }

    @Test func aChunkSplitAcrossTwoReadsArrivesOnTheSecond() throws {
        var parser = ChunkParser()
        #expect(try parser.chunks(from: bytes("5\n[[")).isEmpty)
        #expect(try parser.chunks(from: bytes("0]]")) == ["[[0]]"])
    }

    @Test func aLengthPrefixSplitAcrossReadsIsNotMisread() throws {
        var parser = ChunkParser()
        // "1" alone is a valid-looking length until the "5" and newline arrive.
        #expect(try parser.chunks(from: bytes("1")).isEmpty)
        #expect(try parser.chunks(from: bytes("3\n[[0],[1],[2]]")) == ["[[0],[1],[2]]"])
    }

    @Test func anEmptyReadYieldsNothing() throws {
        var parser = ChunkParser()
        #expect(try parser.chunks(from: []).isEmpty)
    }

    /// The parser frames; it does not interpret. A keepalive is a chunk like
    /// any other and the layer above decides what `noop` means.
    @Test func aKeepaliveIsReturnedLikeAnyOtherChunk() throws {
        var parser = ChunkParser()
        #expect(try parser.chunks(from: bytes("14\n[[1,[\"noop\"]]]")) == ["[[1,[\"noop\"]]]"])
    }

    @Test func aZeroLengthChunkIsAnEmptyPayloadRatherThanAStall() throws {
        var parser = ChunkParser()
        #expect(try parser.chunks(from: bytes("0\n5\n[[0]]")) == ["", "[[0]]"])
    }

    /// §4's headline: framing left zero characters unframed.
    @Test func nothingIsLeftBehindAfterCompleteChunks() throws {
        var parser = ChunkParser()
        _ = try parser.chunks(from: bytes("5\n[[0]]5\n[[1]]"))
        #expect(parser.bufferedByteCount == 0)
    }

    @Test func anIncompleteTailStaysBuffered() throws {
        var parser = ChunkParser()
        _ = try parser.chunks(from: bytes("5\n[[0]]9\n[[incom"))
        #expect(parser.bufferedByteCount > 0)
    }

    // MARK: - The case live traffic never distinguished (§4)

    /// **The test that separates a correct implementation from a plausible one.**
    ///
    /// The length counts **UTF-16 code units** — JavaScript's `String.length` —
    /// not bytes and not characters. No captured chunk contained a non-BMP
    /// character, so every interpretation agreed on the live data.
    ///
    /// `[[0,["😀"]]]` is 11 characters, 14 UTF-8 bytes and **12 UTF-16 code
    /// units**, because the emoji is a surrogate pair. A parser counting either
    /// of the other two reads the wrong number and desynchronises the stream
    /// from that point on.
    @Test func theLengthCountsUTF16CodeUnitsNotBytesOrCharacters() throws {
        let payload = "[[0,[\"😀\"]]]"
        #expect(payload.count == 11)
        #expect(payload.utf8.count == 14)
        #expect(payload.utf16.count == 12)

        var parser = ChunkParser()
        let framed = try parser.chunks(from: bytes("12\n" + payload))
        #expect(framed == [payload])
        #expect(parser.bufferedByteCount == 0)
    }

    /// A following chunk proves the stream did not desynchronise: a parser that
    /// consumed the wrong number of units would misread this one's prefix.
    @Test func aChunkAfterANonBMPOneIsStillFramedCorrectly() throws {
        var parser = ChunkParser()
        let read = bytes("12\n[[0,[\"😀\"]]]") + bytes("5\n[[1]]")
        #expect(try parser.chunks(from: read) == ["[[0,[\"😀\"]]]", "[[1]]"])
    }

    /// A surrogate pair straddling a **raw read** boundary.
    ///
    /// The four UTF-8 bytes of an emoji can be split by the socket anywhere. A
    /// decoder that is not incremental turns the fragment into a replacement
    /// character and silently corrupts the payload — and because the corruption
    /// is one character wide, everything downstream still parses.
    @Test func anEmojiSplitAcrossRawReadsIsNotCorrupted() throws {
        var parser = ChunkParser()
        let all = bytes("12\n[[0,[\"😀\"]]]")
        // "12\n[[0,[\"" is 9 bytes; the emoji's four bytes start at index 9.
        let cut = 9 + 2
        #expect(try parser.chunks(from: Array(all[0 ..< cut])).isEmpty)
        #expect(try parser.chunks(from: Array(all[cut...])) == ["[[0,[\"😀\"]]]"])
    }

    /// Every possible split point of a chunk carrying a non-BMP character.
    ///
    /// One hand-picked boundary proves one boundary. The bug this guards is a
    /// decoder that mishandles a particular offset into a multi-byte sequence,
    /// so the honest test is all of them.
    @Test func everySplitPointOfANonBMPChunkReassembles() throws {
        let payload = "[[0,[\"😀\",\"é\"]]]"
        let all = bytes("\(payload.utf16.count)\n" + payload)
        for cut in 0 ... all.count {
            var parser = ChunkParser()
            var got = try parser.chunks(from: Array(all[0 ..< cut]))
            got += try parser.chunks(from: Array(all[cut...]))
            #expect(got == [payload], "split at \(cut)")
            #expect(parser.bufferedByteCount == 0, "split at \(cut)")
        }
    }

    // MARK: - Refusing to be led on

    @Test func aNonNumericLengthPrefixIsReported() {
        var parser = ChunkParser()
        #expect(throws: ChunkParserError.self) {
            try parser.chunks(from: bytes("oops\n[[0]]"))
        }
    }

    @Test func anEmptyLengthPrefixIsReported() {
        var parser = ChunkParser()
        #expect(throws: ChunkParserError.self) {
            try parser.chunks(from: bytes("\n[[0]]"))
        }
    }

    /// A declared length nobody could mean must not become an unbounded buffer.
    ///
    /// Waiting for more data is the right response to a chunk that has not
    /// finished arriving, and the wrong response to a length that will never be
    /// satisfied - the difference is a client that grows until it is killed.
    @Test func anAbsurdDeclaredLengthIsReportedRatherThanBufferedForever() {
        var parser = ChunkParser()
        #expect(throws: ChunkParserError.self) {
            try parser.chunks(from: bytes("999999999\n[[0]]"))
        }
    }

    @Test func aLengthTooLargeToParseIsReported() {
        var parser = ChunkParser()
        #expect(throws: ChunkParserError.self) {
            try parser.chunks(from: bytes("99999999999999999999999999\n[[0]]"))
        }
    }
}
