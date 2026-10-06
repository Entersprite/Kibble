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
