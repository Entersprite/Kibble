import CryptoKit
import Foundation
import LocalBridgeBackend

extension ProviderProof {
    static var native: ProviderProof {
        ProviderProof { input in
            Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
