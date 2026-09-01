import Foundation

/// Picks an avatar colour from an identifier.
///
/// **Not `hashValue`.** Swift seeds its hasher randomly per process, so a
/// palette chosen that way would repaint every avatar in the app on every
/// launch - a bug that looks like a rendering glitch and is maddening to trace.
/// FNV-1a is fixed, tiny, and pinned by a test.
public enum AvatarPalette {
    public static func index(for identifier: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return Int(hash % UInt64(count))
    }
}
