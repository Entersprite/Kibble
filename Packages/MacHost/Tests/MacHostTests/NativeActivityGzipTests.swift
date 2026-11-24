import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

struct NativeActivityGzipTests {
    @Test func decodesAGzipMemberProducedByAnIndependentEncoder() throws {
        let frame = try fixture()
        let payload = Data([18, 6, 8, 7, 26, 2, 8, 1])
        #expect(try NativeActivityGzip.decode(frame) == payload)
        let encoded = try NativeActivityGzip.encode(payload)
        #expect(encoded.prefix(3) == Data([0x1F, 0x8B, 8]))
        #expect(try NativeActivityGzip.decode(encoded) == payload)
    }

    @Test func refusesTruncatedCorruptOrMultipleMembers() throws {
        let frame = try fixture()
        var corrupt = frame
        corrupt[corrupt.count - 8] ^= 1
        for invalid in [Data(frame.dropLast()), corrupt, frame + frame, Data(repeating: 0, count: 25)] {
            #expect(throws: CallMediaError.connectionFailed) {
                try NativeActivityGzip.decode(invalid)
            }
        }
    }

    @Test func enforcesTheDecodedCaptionLimitEvenWithAFalseSize() throws {
        // Python's gzip.compress(b'A' * size, mtime=0) for 256000 and 256001 bytes.
        let prefix = "H4sIAAAAAAAC/+3BMQEAAADCoGzrX8oQvkAB" + String(repeating: "A", count: 329)
        let atLimit = try #require(Data(base64Encoded: prefix + "HwGZp+1GADoAwA="))
        let expected = Data(repeating: 65, count: NativeActivityGzip.maximumInboundBytes)
        #expect(try NativeActivityGzip.decode(atLimit) == expected)
        let frame = try #require(Data(base64Encoded: prefix + "JwGee8QdwHoAwA="))
        #expect(frame.suffix(4) == Data([1, 232, 3, 0]))
        #expect(throws: CallMediaError.connectionFailed) {
            try NativeActivityGzip.decode(frame)
        }
        var falseSize = frame
        falseSize.replaceSubrange((falseSize.endIndex - 4) ..< falseSize.endIndex, with: [1, 0, 0, 0])
        #expect(throws: CallMediaError.connectionFailed) {
            try NativeActivityGzip.decode(falseSize)
        }
    }

    private func fixture() throws -> Data {
        try #require(Data(base64Encoded: "H4sIAAAAAAAC/xNi42CXYuJgBABzW+HlCAAAAA=="))
    }
}
