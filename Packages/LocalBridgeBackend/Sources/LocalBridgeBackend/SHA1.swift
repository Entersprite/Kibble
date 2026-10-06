import CryptoKit
import Foundation

/// SHA-1 as lowercase hex, for `SAPISIDHash`. Here, not in the core, because
/// the core compiles on Linux without CryptoKit.
enum SHA1 {
    static func hex(_ input: String) -> String {
        Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
