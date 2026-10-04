import Foundation
import Testing
@testable import GChatBridgeCore

/// `Emoji` field 2 is purple's `CustomEmoji` (`reference/purple-googlechat-master/
/// googlechat.proto:163-183`). Bytes built by hand, so the test does not trust
/// the generated encoder it is checking.
struct EmojiProtoTests {
    private func field(_ number: UInt8, _ payload: Data) -> Data {
        var bytes = Data([(number << 3) | 2, UInt8(payload.count)])
        bytes.append(payload)
        return bytes
    }

    @Test func aCustomEmojiDecodesIntoNamedFields() throws {
        var custom = field(1, Data("uuid-1".utf8))
        custom.append(field(3, Data(":parrot:".utf8)))
        custom.append(field(11, Data("https://example.invalid/e".utf8)))
        let emoji = try Emoji(serializedBytes: field(2, custom))
        #expect(emoji.hasCustomEmoji)
        #expect(emoji.customEmoji.uuid == "uuid-1")
        #expect(emoji.customEmoji.shortcode == ":parrot:")
        #expect(emoji.customEmoji.ephemeralURL == "https://example.invalid/e")
        #expect(emoji.unknownFields.data.isEmpty)
    }

    @Test func aUnicodeEmojiStillDecodes() throws {
        let emoji = try Emoji(serializedBytes: field(1, Data("👍".utf8)))
        #expect(emoji.unicode == "👍")
        #expect(!emoji.hasCustomEmoji)
    }
}
