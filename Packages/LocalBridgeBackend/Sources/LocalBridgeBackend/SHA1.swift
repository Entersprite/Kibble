import Foundation

/// Portable SHA-1 for the provider's existing cookie-proof protocol only.
/// Algorithm: https://www.rfc-editor.org/rfc/rfc3174, section 6.1.
enum SHA1 {
    static func hex(_ input: String) -> String {
        var bytes = Array(input.utf8)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> shift))
        }
        var digest: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            compress(Array(bytes[offset ..< (offset + 64)]), digest: &digest)
        }
        return digest.map { String(format: "%08x", $0) }.joined()
    }

    private static func compress(_ bytes: [UInt8], digest: inout [UInt32]) {
        var words = [UInt32](repeating: 0, count: 80)
        for index in 0 ..< 16 {
            let offset = index * 4
            words[index] = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        for index in 16 ..< 80 {
            words[index] = rotate(
                words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16],
                by: 1
            )
        }
        var first = digest[0]
        var second = digest[1]
        var third = digest[2]
        var fourth = digest[3]
        var fifth = digest[4]
        for index in 0 ..< 80 {
            let (mixed, constant) = round(index, second: second, third: third, fourth: fourth)
            let next = rotate(first, by: 5) &+ mixed &+ fifth &+ constant &+ words[index]
            fifth = fourth
            fourth = third
            third = rotate(second, by: 30)
            second = first
            first = next
        }
        digest[0] &+= first
        digest[1] &+= second
        digest[2] &+= third
        digest[3] &+= fourth
        digest[4] &+= fifth
    }

    private static func rotate(_ word: UInt32, by bits: UInt32) -> UInt32 {
        word << bits | word >> (32 - bits)
    }

    private static func round(
        _ index: Int,
        second: UInt32,
        third: UInt32,
        fourth: UInt32
    ) -> (UInt32, UInt32) {
        switch index {
        case 0 ..< 20: ((second & third) | (~second & fourth), 0x5A82_7999)
        case 20 ..< 40: (second ^ third ^ fourth, 0x6ED9_EBA1)
        case 40 ..< 60: ((second & third) | (second & fourth) | (third & fourth), 0x8F1B_BCDC)
        default: (second ^ third ^ fourth, 0xCA62_C1D6)
        }
    }
}
