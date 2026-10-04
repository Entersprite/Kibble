import ChatKit
import CoreGraphics
import SwiftUI

/// What a person can do to a message's reactions. **Optional on
/// `ChatSceneActions`, and `nil` is the point** (`CLAUDE.md`: never draw a
/// control the seam cannot honour): without it the row is read-only and the
/// bubble has no menu.
@MainActor
public struct ReactionActions {
    /// The message, the emoji, and whether to add (`false` removes).
    public var toggle: (Message.ID, ReactionChoice, Bool) -> Void
    /// A custom emoji's picture. `nil` when the backend cannot fetch one:
    /// every custom capsule then shows its shortcode (reactions spec §4.4).
    public var customImage: ((CustomEmojiRef) async throws -> Data)?

    public init(
        toggle: @escaping (Message.ID, ReactionChoice, Bool) -> Void,
        customImage: ((CustomEmojiRef) async throws -> Data)? = nil
    ) {
        self.toggle = toggle
        self.customImage = customImage
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

    /// The picture's side, in points: about the height of the capsule's
    /// emoji glyph at `.caption2`.
    static let imageSide: CGFloat = 14

    /// The emoji to fetch a picture for: a custom one, and only when the host
    /// supplied a loader.
    static func imageRequest(for reaction: Reaction, canLoad: Bool) -> CustomEmojiRef? {
        canLoad ? reaction.customEmoji : nil
    }

    /// Decoded small: a capsule never needs more than a few dozen pixels.
    /// `nil` for bytes ImageIO cannot read, which keeps the shortcode.
    static func image(from data: Data) -> CGImage? {
        AttachmentLayout.decode(data, maxPixel: 64)
    }
}

struct ReactionRow: View {
    let reactions: [Reaction]
    /// `nil` draws plain capsules; set, each capsule toggles the person's own
    /// reaction for its emoji.
    var toggle: ((ReactionChoice, Bool) -> Void)?
    /// A custom emoji's picture; `nil` shows shortcodes.
    var loadImage: ((CustomEmojiRef) async throws -> Data)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.key) { reaction in
                if let toggle {
                    Button {
                        toggle(reaction.choice, !reaction.includesMe)
                    } label: {
                        ReactionCapsule(reaction: reaction, loadImage: loadImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ReactionDisplay.accessibilityLabel(for: reaction))
                } else {
                    ReactionCapsule(reaction: reaction, loadImage: loadImage)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ReactionDisplay.accessibilityLabel(for: reaction))
                }
            }
        }
    }
}

/// One emoji and its count. A custom emoji shows its picture once loaded,
/// and its `:shortcode:` before that, without a loader, or when the bytes
/// do not decode (reactions spec §4.1, §5): a failure has no other sign.
struct ReactionCapsule: View {
    let reaction: Reaction
    var loadImage: ((CustomEmojiRef) async throws -> Data)?
    @State private var image: CGImage?

    /// `image` is for a render harness, which cannot run `.task`.
    init(
        reaction: Reaction,
        loadImage: ((CustomEmojiRef) async throws -> Data)? = nil,
        image: CGImage? = nil
    ) {
        self.reaction = reaction
        self.loadImage = loadImage
        _image = State(initialValue: image)
    }

    var body: some View {
        HStack(spacing: 3) {
            if let image {
                Image(image, scale: 1, label: Text(reaction.emoji))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: ReactionDisplay.imageSide, height: ReactionDisplay.imageSide)
            } else {
                Text(reaction.emoji)
            }
            Text("\(reaction.count)").monospacedDigit()
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(reaction.includesMe ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quinary))
        .clipShape(Capsule())
        .task(id: ReactionDisplay.imageRequest(for: reaction, canLoad: loadImage != nil)?.id) {
            guard let loadImage, image == nil,
                  let emoji = ReactionDisplay.imageRequest(for: reaction, canLoad: true)
            else { return }
            image = await (try? loadImage(emoji)).flatMap(ReactionDisplay.image(from:))
        }
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
