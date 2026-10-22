import Foundation

public extension Capabilities {
    var canSendCustomEmoji: Bool {
        extendedFlags.contains("customEmojiMessages")
    }

    var canSetCustomEmojiStatus: Bool {
        extendedFlags.contains("customEmojiStatus")
    }

    var canForwardMessages: Bool {
        extendedFlags.contains("forwardMessages")
    }

    var canFormatMessages: Bool {
        extendedFlags.contains("formattedMessages")
    }

    var canQuoteMessages: Bool {
        extendedFlags.contains("quotedMessages")
    }
}
