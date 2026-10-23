import ChatKit
import Foundation

/// The Details section's unsaved edits, beside the values they started from.
///
/// Save sends only what changed and what the server allows: an untouched
/// field is omitted, an emptied one is sent as `""` to clear it, and an
/// emoji of `""` restores the default icon. Lengths are UTF-16 units, as
/// the server counts them, against the limits it supplied.
struct DetailsDraft: Equatable {
    var name: String
    var description: String
    var guidelines: String
    /// The space's emoji. `nil` or `""` is the default icon.
    var emoji: String?

    private let original: Values
    private let editable: Set<Field>
    private let limits: [String: Int]
    private let isSpace: Bool

    /// One editable field: the action that allows it and its limit's key.
    enum Field: String, CaseIterable {
        case name, description, guidelines, emoji

        var action: String {
            self == .name ? "rename" : rawValue
        }
    }

    private struct Values: Equatable {
        var name: String
        var description: String
        var guidelines: String
        var emoji: String?
    }

    init(_ details: ConversationDetails) {
        let values = Values(
            name: details.conversation.title ?? "",
            description: details.description ?? "",
            guidelines: details.guidelines ?? "",
            emoji: details.settings?.emoji
        )
        original = values
        name = values.name
        description = values.description
        guidelines = values.guidelines
        emoji = values.emoji
        limits = details.fieldLimits
        let kind = details.conversation.kind
        isSpace = kind == .space
        let allowed = details.allowedActions
        editable = Set(Field.allCases.filter { field in
            guard allowed.contains("details"), allowed.contains(field.action) else { return false }
            switch kind {
            case .space: return true
            case .groupDirectMessage: return field == .name
            default: return false
            }
        })
    }

    /// Whether the server lets this conversation's `field` be changed here.
    func canEdit(_ field: Field) -> Bool {
        editable.contains(field)
    }

    /// The server's limit for `"name"`, `"description"` or `"guidelines"`, if it gave one.
    func limit(_ field: String) -> Int? {
        limits[field]
    }

    /// What the server counts: UTF-16 units, so "👍🏽" is 4.
    static func length(_ text: String) -> Int {
        text.utf16.count
    }

    /// Whether `text` fits the server's limit for `field`. No limit, no check.
    func fits(_ text: String, _ field: Field) -> Bool {
        limit(field.rawValue).map { Self.length(text) <= $0 } ?? true
    }

    var isDirty: Bool {
        patch() != nil
    }

    /// Whether Save can send this: every changed field within its limit, and
    /// a space's name not blank. Unchanged fields are not sent, so not checked.
    var isValid: Bool {
        guard let patch = patch() else { return true }
        if let name = patch.name {
            if !fits(name, .name) {
                return false
            }
            if isSpace, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        if let description = patch.description, !fits(description, .description) {
            return false
        }
        if let guidelines = patch.guidelines, !fits(guidelines, .guidelines) {
            return false
        }
        return true
    }

    /// The changed, allowed fields; nil when there is nothing to send.
    func patch() -> ConversationDetailsPatch? {
        var patch = ConversationDetailsPatch()
        if canEdit(.name), name != original.name {
            patch.name = name
        }
        if canEdit(.description), description != original.description {
            patch.description = description
        }
        if canEdit(.guidelines), guidelines != original.guidelines {
            patch.guidelines = guidelines
        }
        if canEdit(.emoji), (emoji ?? "") != (original.emoji ?? "") {
            patch.emoji = emoji ?? ""
        }
        return patch == ConversationDetailsPatch() ? nil : patch
    }

    /// This draft over `details` read again: what the person changed stays,
    /// everything else takes the new values. When the reload is the saved
    /// answer, the edits match it and the draft is clean.
    func rebased(onto details: ConversationDetails) -> DetailsDraft {
        var next = DetailsDraft(details)
        if name != original.name {
            next.name = name
        }
        if description != original.description {
            next.description = description
        }
        if guidelines != original.guidelines {
            next.guidelines = guidelines
        }
        if (emoji ?? "") != (original.emoji ?? "") {
            next.emoji = emoji
        }
        return next
    }
}
