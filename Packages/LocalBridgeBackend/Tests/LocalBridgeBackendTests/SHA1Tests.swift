import Foundation
import Testing
@testable import LocalBridgeBackend

/// `SHA1.hex`, which signs the people search's `SAPISIDHASH`.
struct SHA1Tests {
    /// `python3 -c 'import hashlib; print(hashlib.sha1(b"1700000000 sap-1
    /// https://chat.google.com").hexdigest())'`
    @Test func matchesAKnownVector() {
        #expect(SHA1
            .hex("1700000000 sap-1 https://chat.google.com") == "0cdf34bd486e3b4f14ed3eb372ae19228144c08d")
    }
}

struct PortableProofVectorTests {
    @Test(arguments: [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        )
    ])
    func canonicalVectors(input: String, expected: String) {
        #expect(ProviderProof.portable.sha1Hex(input) == expected)
    }
}
