import Foundation
import Testing
@testable import GChatBridgeCore

@Suite("APIResponseBody")
struct APIResponseBodyTests {
    /// A real protobuf body. Field 1, varint 3, then field 2, length-delimited
    /// "hi" - bytes that are not valid base64, which is the common case.
    private let binary = Data([0x08, 0x03, 0x12, 0x02, 0x68, 0x69])

    @Test func rawBinaryIsOfferedAsRawAndNothingElse() {
        let candidates = APIResponseBody.candidates(binary)
        #expect(candidates.count == 1)
        #expect(candidates.first?.encoding == .raw)
        #expect(candidates.first?.bytes == binary)
    }

    @Test func aBase64BodyIsOfferedDecodedFirst() {
        let encoded = Data(binary.base64EncodedString().utf8)
        let candidates = APIResponseBody.candidates(encoded)
        #expect(candidates.first?.encoding == .base64)
        #expect(candidates.first?.bytes == binary)
    }

    /// "Attempt base64, fall back to raw" (§3.6) means both must survive the
    /// offer, because a short protobuf can be accidentally valid base64 and
    /// picking wrong must not be terminal.
    @Test func aBase64LookingBodyStillOffersRawAsTheFallback() {
        let encoded = Data(binary.base64EncodedString().utf8)
        let candidates = APIResponseBody.candidates(encoded)
        #expect(candidates.count == 2)
        #expect(candidates.last?.encoding == .raw)
        #expect(candidates.last?.bytes == encoded)
    }

    /// The ambiguous case the structural test exists for: four bytes that are
    /// all in the base64 alphabet and are also a perfectly good protobuf.
    /// It must be offered both ways rather than committed to either.
    @Test func anAmbiguousShortBodyIsOfferedBothWays() {
        let ambiguous = Data("CAMS".utf8)
        let candidates = APIResponseBody.candidates(ambiguous)
        #expect(candidates.map(\.encoding) == [.base64, .raw])
    }

    @Test func aLengthThatIsNotAMultipleOfFourIsNotBase64() {
        #expect(APIResponseBody.looksBase64(Data("CAM".utf8)) == false)
    }

    @Test func aByteOutsideTheAlphabetIsNotBase64() {
        #expect(APIResponseBody.looksBase64(Data([0x43, 0x41, 0x4D, 0x00])) == false)
    }

    @Test func paddingIsPartOfTheAlphabet() {
        #expect(APIResponseBody.looksBase64(Data("CAMS/w==".utf8)) == true)
    }

    /// §3.6 is why this file exists: an assumption about the wire format
    /// turned out wrong, so on an encoding shape not yet observed live,
    /// tolerating it is the correct side to be wrong on. A trailing newline is
    /// a plausible shape for a base64 body - not a corner case - and must not
    /// disqualify it: measured, `Data(base64Encoded:)` rejects it outright
    /// with the default options.
    @Test func aTrailingNewlineDoesNotDisqualifyABase64Body() {
        let withTrailingNewline = Data((binary.base64EncodedString() + "\n").utf8)
        let candidates = APIResponseBody.candidates(withTrailingNewline)
        #expect(candidates.first?.encoding == .base64)
        #expect(candidates.first?.bytes == binary)
    }

    /// MIME base64 conventionally wraps at 76 columns, so a body broken across
    /// lines is a plausible shape a real response could take, not a corner
    /// case invented for coverage.
    @Test func lineWrappedBase64IsStillRecognised() {
        let wrapped = Data("CAMS\nAmhp".utf8)
        let candidates = APIResponseBody.candidates(wrapped)
        #expect(candidates.first?.encoding == .base64)
        #expect(candidates.first?.bytes == binary)
    }

    /// The boundary this fix must not cross: stripping whitespace before the
    /// length check must not let an otherwise-invalid raw body slip past the
    /// alphabet check just because removing a newline happens to leave a
    /// multiple of four bytes behind. "CAM" plus a byte outside the alphabet,
    /// with a newline spliced in - after stripping, four bytes remain, so only
    /// the alphabet check (not the length check) can catch the invalid byte.
    @Test func rawBinaryContainingANewlineByteIsStillNotMisreadAsBase64() {
        let withNewlineByte = Data([0x43, 0x41, 0x0A, 0x4D, 0x00])
        #expect(APIResponseBody.looksBase64(withNewlineByte) == false)
        #expect(APIResponseBody.candidates(withNewlineByte).map(\.encoding) == [.raw])
    }

    @Test func anEmptyBodyOffersNothing() {
        #expect(APIResponseBody.candidates(Data()).isEmpty)
    }
}
