import ChatKit
import SwiftUI

/// What a person can do to a message's reactions. **Optional on
/// `ChatSceneActions`, and `nil` is the point** (`CLAUDE.md`: never draw a
/// control the seam cannot honour): without it the row is read-only and the
/// bubble has no menu.
@MainActor
public struct ReactionActions {
    /// The message, the emoji, and whether to add (`false` removes).
    public var toggle: (Message.ID, ReactionChoice, Bool) -> Void

    public init(toggle: @escaping (Message.ID, ReactionChoice, Bool) -> Void) {
        self.toggle = toggle
    }
}

/// The context menu's six (reactions spec §4.2). Recents replace them in
/// slice 2.
enum QuickReactions {
    static let defaults = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    /// Whether choosing `choice` adds it: not when it is already the person's,
    /// which makes the menu a toggle like the capsule.
    static func adds(_ choice: ReactionChoice, to reactions: [Reaction]) -> Bool {
        !reactions.contains { $0.key == choice.key && $0.includesMe }
    }
}

enum ReactionDisplay {
    /// "👍, 2, you reacted". The emoji is spoken by VoiceOver; a custom emoji
    /// is its shortcode, which `emoji` already holds.
    static func accessibilityLabel(for reaction: Reaction) -> String {
        let base = "\(reaction.emoji), \(reaction.count)"
        return reaction.includesMe ? "\(base), you reacted" : base
    }
}

struct ReactionRow: View {
    let reactions: [Reaction]
    /// `nil` draws plain capsules; set, each capsule toggles the person's own
    /// reaction for its emoji.
    var toggle: ((ReactionChoice, Bool) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.key) { reaction in
                if let toggle {
                    Button {
                        toggle(reaction.choice, !reaction.includesMe)
                    } label: {
                        ReactionCapsule(reaction: reaction)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ReactionDisplay.accessibilityLabel(for: reaction))
                } else {
                    ReactionCapsule(reaction: reaction)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ReactionDisplay.accessibilityLabel(for: reaction))
                }
            }
        }
    }
}

/// One emoji and its count. A custom emoji shows its shortcode until plan 1b
/// gives it an image.
struct ReactionCapsule: View {
    let reaction: Reaction

    var body: some View {
        HStack(spacing: 3) {
            Text(reaction.emoji)
            Text("\(reaction.count)").monospacedDigit()
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(reaction.includesMe ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quinary))
        .clipShape(Capsule())
    }
}

/// The bubble's context menu: the quick set as one palette row
/// (`ControlGroup` + `.palette`, macOS 14+). Nothing at all when there are no
/// actions or the message is deleted.
struct ReactionMenu: ViewModifier {
    let message: Message
    let actions: ReactionActions?

    func body(content: Content) -> some View {
        if let actions, !message.isDeleted {
            content.contextMenu {
                ControlGroup {
                    ForEach(QuickReactions.defaults, id: \.self) { emoji in
                        let choice = ReactionChoice(emoji: emoji)
                        Button(emoji) {
                            actions.toggle(
                                message.id,
                                choice,
                                QuickReactions.adds(choice, to: message.reactions)
                            )
                        }
                    }
                }
                .controlGroupStyle(.palette)
            }
        } else {
            content
        }
    }
}
