import Foundation

/// A message as the composer hands it over: the text to send and the mentions
/// inside it, spans in UTF-16 code units like every `Mention` (`findings.md`
/// §41.1). Also what a refused send hands back to the composer, so a resend
/// still mentions (mention composer spec §2).
///
/// Not part of the wire format: no `ChatCommand` or `ChatEvent` carries one,
/// so it is not `Codable` and has no golden.
public struct ComposedMessage: Hashable, Sendable {
    public var text: String
    public var mentions: [Mention]

    public init(text: String, mentions: [Mention] = []) {
        self.text = text
        self.mentions = mentions
    }
}
