import ChatKit
import Foundation

/// What Convert to Space sends: a name, an optional single emoji, and the
/// history acknowledgement. The name's length is counted in UTF-16 units
/// against the server's limit, without the spaces around it, which aren't sent.
struct ConversionDraft: Equatable {
    var name: String
    /// One character, or nil (or "") for the default icon.
    var emoji: String?
    var acknowledged = false

    init(name: String) {
        self.name = name
    }

    /// Whether these details still let the person convert: a group chat
    /// whose server allows it. A read can take the permission away.
    static func allows(_ details: ConversationDetails) -> Bool {
        details.conversation.kind == .groupDirectMessage && details.allowedActions.contains("convertToSpace")
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isNameValid(limit: Int?) -> Bool {
        let name = trimmedName
        return !name.isEmpty && (limit.map { DetailsDraft.length(name) <= $0 } ?? true)
    }

    /// Whether Convert can be offered: the current details still allow it,
    /// the consequences have arrived and aren't being read again, the last
    /// read didn't fail, the name fits the details' limit, and the
    /// acknowledgement is ticked if required.
    func isReady(
        details: ConversationDetails?,
        conversion: ConversionConsequences?,
        isLoadingConversion: Bool = false,
        conversionError: String? = nil
    ) -> Bool {
        guard let details, Self.allows(details), let conversion, !isLoadingConversion,
              conversionError == nil else { return false }
        return isNameValid(limit: details.fieldLimits["name"])
            && (acknowledged || !conversion.requiresHistoryAcknowledgement)
    }

    /// Takes a picked emoji only if it is the one character the server accepts.
    mutating func choose(_ emoji: String?) {
        guard let emoji, emoji.count == 1 else { return }
        self.emoji = emoji
    }

    /// Always acknowledges the history change. Convert is offered only once
    /// the person has ticked it wherever the server asks for it, and the
    /// backends refuse any conversion that doesn't acknowledge it.
    var mutation: ConversationMutation {
        .convertToSpace(
            name: trimmedName,
            emoji: emoji.flatMap { $0.isEmpty ? nil : $0 },
            acknowledgingHistoryChange: true
        )
    }
}
