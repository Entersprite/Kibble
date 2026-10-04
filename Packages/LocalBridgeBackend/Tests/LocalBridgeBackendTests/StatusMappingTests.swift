import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

/// `user_status.custom_status` becoming `MemberStatus`. Field numbers from the
/// vendored proto, including `Emoji.custom_emoji` (2), now named since the
/// reactions slice merged purple's `Emoji`/`CustomEmoji` into it.
struct StatusMappingTests {
    private func entry(_ id: String, _ build: (inout UserStatus) -> Void) -> UserPresence {
        var entry = UserPresence()
        entry.userID.id = id
        var status = UserStatus()
        build(&status)
        entry.userStatus = status
        return entry
    }

    private func map(_ entries: [UserPresence]) -> [ChatKit.Member.ID: MemberStatus?] {
        var response = GetUserPresenceResponse()
        response.userPresences = entries
        return PresenceMapping.statuses(response, now: now)
    }

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private let ada = ChatKit.Member.ID("u-1")

    @Test func aUnicodeEmojiTextAndExpiry() {
        let mapped = map([entry("u-1") {
            $0.customStatus.emoji.unicode = "🌴"
            $0.customStatus.statusText = "On vacation"
            $0.customStatus.stateExpiryTimestampUsec = 1_790_000_000_000_000
        }])
        #expect(mapped[ada] == MemberStatus(
            emoji: "🌴", text: "On vacation", expiresAt: Date(timeIntervalSince1970: 1_790_000_000)
        ))
    }

    /// A status already past its expiry is none, whatever the server still
    /// sends, so the poll clears it within one interval rather than leaving
    /// it until the row happens to redraw. Mapping it through turns this red.
    @Test func anExpiredStatusIsNone() {
        let mapped = map([entry("u-1") {
            $0.customStatus.emoji.unicode = "🌴"
            $0.customStatus.stateExpiryTimestampUsec = 1_780_000_000_000_000
        }])
        #expect(mapped[ada] == .some(nil))
    }

    /// The older `status_emoji` string, when there is no `Emoji` message.
    @Test func theOlderEmojiString() {
        let mapped = map([entry("u-1") { $0.customStatus.statusEmoji = "🤒" }])
        #expect(mapped[ada] == MemberStatus(emoji: "🤒"))
    }

    /// A custom image emoji is `Emoji.custom_emoji` (`CustomEmoji`, field 2),
    /// whose `shortcode` (field 3) the vendored proto now names directly -
    /// the reactions slice merged purple's `Emoji`/`CustomEmoji` into it.
    @Test func aCustomEmojiIsReadFromTheBytes() throws {
        let shortcode = Data(":party-parrot:".utf8)
        var custom = Data([0x1A, UInt8(shortcode.count)])
        custom.append(shortcode)
        var bytes = Data([0x12, UInt8(custom.count)])
        bytes.append(custom)
        let emoji = try Emoji(serializedBytes: bytes)
        // Positive control: the vendored proto now names it directly.
        #expect(emoji.hasCustomEmoji)

        let mapped = map([entry("u-1") {
            $0.customStatus.emoji = emoji
            $0.customStatus.statusText = "Shipped"
        }])
        #expect(mapped[ada] == MemberStatus(customEmojiShortcode: ":party-parrot:", text: "Shipped"))
    }

    /// Empty strings are "nothing", and nothing at all is a cleared status:
    /// the entry is answered, so the key is there, with `nil`.
    @Test func noCustomStatusIsAClearedStatus() {
        let mapped = map([
            entry("u-1") { $0.customStatus.statusText = "" },
            entry("u-2") { $0.dndSettings.dndState = .available }
        ])
        #expect(mapped.count == 2)
        #expect(mapped[ada] == .some(nil))
        #expect(mapped[ChatKit.Member.ID("u-2")] == .some(nil))
    }

    /// No `user_status` at all says nothing about a status - "nobody told
    /// us" - so no key, and nothing is cleared.
    @Test func noUserStatusIsNotAnAnswer() {
        var bare = UserPresence()
        bare.userID.id = "u-1"
        bare.presence = .active
        #expect(map([bare]).isEmpty)
    }
}
