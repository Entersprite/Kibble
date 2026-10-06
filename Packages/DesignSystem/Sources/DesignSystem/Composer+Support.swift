import ChatKit
import SwiftUI

// The composer's small private types, apart for `Composer.swift`'s length.

/// A send waiting on the confirmation: the message, and who is outside.
struct PendingInvite: Identifiable {
    let id = UUID()
    let message: ComposedMessage
    let people: [Member.ID]
}

/// Where the field is, for placing the `@` list above it.
struct ComposerFieldAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
