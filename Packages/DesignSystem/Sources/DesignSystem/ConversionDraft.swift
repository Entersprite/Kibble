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
    /// the consequences have arrived and aren't being read again, the name
    /// fits the details' limit, and the acknowledgement is ticked if required.
    func isReady(
        details: ConversationDetails?,
        conversion: ConversionConsequences?,
        isLoadingConversion: Bool = false
    ) -> Bool {
        guard let details, Self.allows(details), let conversion, !isLoadingConversion else { return false }
        return isNameValid(limit: details.fieldLimits["name"])
            && (acknowledged || !conversion.requiresHistoryAcknowledgement)
    }

    /// Takes a picked emoji only if it is the one character the server accepts.
    mutating func choose(_ emoji: String?) {
        guard let emoji, emoji.count == 1 else { return }
        self.emoji = emoji
    }

    var mutation: ConversationMutation {
        .convertToSpace(
            name: trimmedName,
            emoji: emoji.flatMap { $0.isEmpty ? nil : $0 },
            acknowledgingHistoryChange: true
        )
    }
}
