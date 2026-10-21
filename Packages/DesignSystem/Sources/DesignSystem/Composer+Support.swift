import ChatKit
import SwiftUI

// The composer's small private types, apart for `Composer.swift`'s length.

/// A send waiting on the confirmation: the message, and who is outside.
struct PendingInvite: Identifiable {
    let id = UUID()
    let message: ComposedMessage
    let people: [Member.ID]

    /// The confirmation's question.
    var title: String {
        let names = ListFormatter.localizedString(byJoining: message.names(of: people))
        return "\(names) " + (people.count == 1 ? "isn't" : "aren't") + " in this space."
    }
}

/// Where the field is, for placing the `@` list above it.
struct ComposerFieldAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// What the field takes from its host, through `updateNSView`: text (the
/// emoji picker), a prefix for each selected line (a list's `- `), or a style
/// to turn on or off. `id` makes the same emoji twice two insertions.
struct ComposerInsertion: Equatable {
    let id = UUID()
    var text = ""
    var linePrefix: String?
    var toggle: ComposerDraft.Style?
}
