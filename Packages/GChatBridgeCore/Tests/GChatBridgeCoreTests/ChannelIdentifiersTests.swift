import Foundation
import Testing
@testable import GChatBridgeCore

/// The two random values every channel request carries.
///
/// Random in production and injectable here, so the requests they go into stay
/// assertable as exact strings. Randomness that cannot be pinned turns every
/// downstream test into a substring match.
struct ChannelIdentifiersTests {
    /// A generator that hands back a fixed sequence, so a "random" value is a
    /// known one. Not a fake for its own sake: the alternative is asserting the
    /// *shape* of a cache-buster, which would pass for a constant.
    private struct FixedGenerator: RandomNumberGenerator {
        var values: [UInt64]
        private var index = 0

        init(_ values: [UInt64]) {
            self.values = values
        }

        mutating func next() -> UInt64 {
            defer { index += 1 }
            return values[index % values.count]
        }
    }

    // MARK: - base36

    @Test func base36EncodesDigitsThenLetters() {
        #expect(ChannelIdentifiers.base36(0) == "0")
        #expect(ChannelIdentifiers.base36(9) == "9")
        #expect(ChannelIdentifiers.base36(10) == "a")
        #expect(ChannelIdentifiers.base36(35) == "z")
        #expect(ChannelIdentifiers.base36(36) == "10")
    }

    @Test func base36HandlesTheWholeRangeOfSixtyFourBits() {
        // 2^64 - 1 in base 36.
        #expect(ChannelIdentifiers.base36(UInt64.max) == "3w5e11264sgsf")
    }

    /// Lowercase, because that is what the reference produces and a request is
    /// only useful if it matches a capture.
    @Test func base36IsLowercase() {
        let encoded = ChannelIdentifiers.base36(1_234_567_890_123)
        #expect(encoded == encoded.lowercased())
    }

    // MARK: - The cache-buster

    @Test func theCacheBusterIsBase36OfSixtyFourRandomBits() {
        var generator = FixedGenerator([36])
        #expect(ChannelIdentifiers.cacheBuster(using: &generator) == "10")
    }

    /// A reopen must not reuse the previous poll's `zx` — the parameter exists
    /// to stop a cache answering, and a repeated value defeats it.
    @Test func consecutiveCacheBustersDiffer() {
        var generator = SystemRandomNumberGenerator()
        let first = ChannelIdentifiers.cacheBuster(using: &generator)
        let second = ChannelIdentifiers.cacheBuster(using: &generator)
        #expect(first != second)
    }

    // MARK: - The request counter

    /// The reference seeds it from `random.randint(10000, 99999)`; the counter
    /// then increments per forward-channel request.
    @Test func theInitialRequestIdentifierIsFiveDigits() {
        for value in [UInt64(0), 1, 12345, UInt64.max] {
            var generator = FixedGenerator([value])
            let rid = ChannelIdentifiers.initialRequestIdentifier(using: &generator)
            #expect((10000 ... 99999).contains(rid), "for \(value)")
        }
    }

    @Test func theRequestIdentifierIsDeterministicForAGivenDraw() {
        var one = FixedGenerator([7])
        var two = FixedGenerator([7])
        #expect(
            ChannelIdentifiers.initialRequestIdentifier(using: &one)
                == ChannelIdentifiers.initialRequestIdentifier(using: &two)
        )
    }
}
