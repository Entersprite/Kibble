import Foundation

public extension Capabilities {
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
