import ChatKit
import SwiftUI

// The composer's small private types, apart for `Composer.swift`'s length.

extension Composer {
    var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            text
                .anchorPreference(key: ComposerFieldAnchor.self, value: .bounds) { $0 }
            scheduleButton
            #if os(macOS)
                if ComposerLayout.offersDictation(draft) {
                    ComposerDictationButton { dictationRequest += 1 }
                }
            #else
                // Only when there is something to send (`ComposerSendButton`).
                if canAct {
                    ComposerSendButton(action: submit)
                        .transition(.scale.combined(with: .opacity))
                }
            #endif
        }
    }

    struct Restoration: Equatable {
        let id: UUID?
        let message: ComposedMessage?
    }

    func restore(_ previous: Restoration, _ offered: Restoration) {
        if offered.id != nil, previous.id != offered.id {
            // A second attempt can have identical text and metadata.
            _ = draft.adopt(nil)
        }
        guard draft.adopt(offered.message, formatting: allowsFormatting) else { return }
        isFocused = true
        focusRequest += 1
        onRestored?()
    }
}

/// A send waiting on the confirmation: the message, who is outside, and how
/// they can be added.
struct PendingInvite: Identifiable {
    let id = UUID()
    let message: ComposedMessage
    let composition: ComposedMessage?
    let people: [Member.ID]
    var adding: ComposerOutsiders.Adding = .byMention
    var place = "space"

    /// Adding before sending needs a host that can: without one, nobody can
    /// be added from here.
    init(
        message: ComposedMessage, composition: ComposedMessage? = nil,
        outsiders: ComposerOutsiders, place: String, canAddBeforeSending: Bool
    ) {
        self.message = message
        self.composition = composition
        people = outsiders.people
        adding = outsiders.adding == .beforeSending && !canAddBeforeSending ? .unavailable : outsiders.adding
        self.place = place
    }

    init(message: ComposedMessage, people: [Member.ID]) {
        self.message = message
        composition = nil
        self.people = people
    }

    /// The confirmation's question.
    var title: String {
        let names = ListFormatter.localizedString(byJoining: message.names(of: people))
        return "\(names) " + (people.count == 1 ? "isn't" : "aren't") + " in this \(place)."
    }

    /// Whether "Add and Send" is offered beside "Send Without Adding".
    var offersAdding: Bool {
        adding != .unavailable
    }

    /// The line under the question.
    var detail: String {
        offersAdding ? "Adding them lets them see this message."
            : "They can't be added from here, so they won't see this message."
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
    var customEmoji: CustomEmojiRef?
    var linePrefix: String?
    var toggle: ComposerDraft.Style?
}
