import CryptoKit
import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

struct ProviderProofTests {
    @Test(arguments: [0, 1, 55, 56, 63, 64, 65, 127, 128, 129, 4096])
    func portableAndNativeAgreeAcrossPaddingBoundaries(length: Int) {
        let input = String(repeating: "x", count: length)
        #expect(ProviderProof.portable.sha1Hex(input) == ProviderProof.native.sha1Hex(input))
    }

    @Test func portableAndNativeAgreeOnUTF8AndManyBlocks() {
        let input = String(repeating: "雪🐕 café ", count: 1024)
        #expect(ProviderProof.portable.sha1Hex(input) == ProviderProof.native.sha1Hex(input))
    }

    @Test func aHostCanInjectItsOwnProofComputation() {
        let proof = ProviderProof { "digest:\($0.utf8.count)" }
        #expect(proof.sha1Hex("proof input") == "digest:11")
    }
}
