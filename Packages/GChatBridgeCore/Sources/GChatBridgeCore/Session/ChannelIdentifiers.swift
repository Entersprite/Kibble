import Foundation

/// The two random values the channel's requests carry.
///
/// Both take a generator rather than reaching for one, so a request built from
/// them is assertable as an exact string. That is not test convenience for its
/// own sake: on a protocol whose specification is a set of captures, a request
/// that cannot be diffed against one is most of the debugging story gone.
public enum ChannelIdentifiers {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// Base-36, lowercase, no padding.
    ///
    /// Lowercase because that is what the reference produces, and the point of
    /// matching is that a request looks like the one that was captured.
    public static func base36(_ value: UInt64) -> String {
        guard value > 0 else { return "0" }
        var value = value
        var characters: [Character] = []
        while value > 0 {
            characters.append(digits[Int(value % 36)])
            value /= 36
        }
        return String(characters.reversed())
    }

    /// `zx` — a cache-buster, base-36 of 64 random bits.
    ///
    /// Freshly generated per request rather than per session: the parameter
    /// exists so that no cache answers a long poll, and reusing one defeats it.
    public static func cacheBuster(using generator: inout some RandomNumberGenerator) -> String {
        base36(generator.next())
    }

    /// `RID`'s seed — five digits, as the reference draws it.
    ///
    /// The counter increments per forward-channel request from here. The range
    /// is presumably arbitrary; it is copied because looking like the reference
    /// costs nothing and being novel might not.
    public static func initialRequestIdentifier(
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        10000 + Int(generator.next() % 90000)
    }
}
