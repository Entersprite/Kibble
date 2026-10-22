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
    /// The person's recent reactions, newest first: the quick row and the
    /// picker's Recent section (reactions slice 2). Called while views render
    /// (a context menu's contents are built with the bubble), so a host must
    /// answer from memory, never from a store read.
    public var recents: () -> [ReactionChoice]
    /// The custom emoji this account has seen, for the picker's Custom
    /// section (spec §2.4's fallback: no catalog call is known). Called while
    /// the picker renders, like `recents`, so a host answers from memory.
    public var customCatalog: () -> [CustomEmojiRef]
    /// The app's one skin tone, and how to change it (spec §3, §4.4).
    public var canComposeCustomEmoji: Bool
    public var canSetCustomEmojiStatus: Bool
    public var skinTone: SkinTone
    public var setSkinTone: (SkinTone) -> Void

    public init(
        toggle: @escaping (Message.ID, ReactionChoice, Bool) -> Void,
        customImage: ((CustomEmojiRef) async throws -> Data)? = nil,
        recents: @escaping () -> [ReactionChoice] = { [] },
        customCatalog: @escaping () -> [CustomEmojiRef] = { [] },
        skinTone: SkinTone = .none,
        canComposeCustomEmoji: Bool = false, canSetCustomEmojiStatus: Bool = false,
        setSkinTone: @escaping (SkinTone) -> Void = { _ in }
    ) {
        self.toggle = toggle
        self.customImage = customImage
        self.recents = recents
        self.customCatalog = customCatalog
        self.skinTone = skinTone
        self.canComposeCustomEmoji = canComposeCustomEmoji
        self.canSetCustomEmojiStatus = canSetCustomEmojiStatus
        self.setSkinTone = setSkinTone
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

/// One emoji of the quick row, for one message: what both the SwiftUI menu
/// and the native text menu draw (native text menu spec §2), so they cannot
/// drift apart.
struct QuickReactionItem: Equatable {
    let emoji: String
    let choice: ReactionChoice
    /// Whether choosing it adds; `false` removes the person's own.
    let adds: Bool
}

enum QuickReactionItems {
    static let count = 6

    /// The six most recent unicode reactions, then the defaults not already
    /// among them (slice 2 plan, ruling 6). A custom recent stays in the
    /// picker's Recent section: a palette cell needs its picture the moment
    /// the menu opens, and a custom emoji's arrives later.
    static func items(for reactions: [Reaction], recents: [ReactionChoice] = []) -> [QuickReactionItem] {
        var emoji: [String] = []
        for candidate in recents.filter({ $0.customEmoji == nil }).map(\.emoji) + QuickReactions.defaults
            where !emoji.contains(candidate) {
            emoji.append(candidate)
            if emoji.count == count {
                break
            }
        }
        return emoji.map { emoji in
            let choice = ReactionChoice(emoji: emoji)
            return QuickReactionItem(
                emoji: emoji,
                choice: choice,
                adds: QuickReactions.adds(choice, to: reactions)
            )
        }
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

    /// What the capsule's image load is keyed on: the whole reference, token
    /// included, so a token that arrives with a later history load restarts
    /// the load in a capsule already on screen. `nil` when nothing loads.
    static func imageTaskKey(for reaction: Reaction, canLoad: Bool) -> CustomEmojiRef? {
        imageRequest(for: reaction, canLoad: canLoad)
    }

    /// Decoded small: a capsule never needs more than a few dozen pixels.
    /// `nil` for bytes ImageIO cannot read, which keeps the shortcode.
    static func image(from data: Data) -> CGImage? {
        AttachmentLayout.decode(data, maxPixel: 64)
    }
}

/// The message's reactions as Messages draws tapbacks: one small bubble
/// hanging from the top corner of what was said, at the trailing corner of
/// someone else's message and the leading corner of yours, overlapping the
/// corner, with two small circles for a tail. Each reaction is its emoji, and
/// its count when more than one person chose it; the ones you chose are blue,
/// as your own tapback is in Messages. Clicking one adds or removes yours.
///
/// The only reaction control on the message: adding one is the context
/// menu's (owner decision), so there is no hover button and no "+".
struct ReactionTapbacks: View {
    let reactions: [Reaction]
    /// Hangs from the leading corner (your message) or the trailing one.
    let isMine: Bool
    /// `nil` draws them read-only; set, each toggles the person's own
    /// reaction for its emoji.
    var toggle: ((ReactionChoice, Bool) -> Void)?
    /// A custom emoji's picture; `nil` shows shortcodes.
    var loadImage: ((CustomEmojiRef) async throws -> Data)?

    /// The bubble's height, and how much of it sits over the message: only
    /// its foot, so it never covers the first line's words.
    static let height: CGFloat = 26
    static let overlap: CGFloat = 6
    /// The room a message with reactions keeps above itself.
    static let rise: CGFloat = height - overlap
    /// How much of its width sits over the message's corner; the rest hangs
    /// past the message's edge, as a tapback does in Messages.
    static let inset: CGFloat = 12
    /// Shown before the rest are counted as "+N", so the bubble stays small.
    static let shown = 5
    /// The ring of window background that sets it off from what it overlaps.
    static let ring: CGFloat = 2

    /// Nothing at all without reactions, so a message's overlay can always
    /// hold one, and the alignment guides placing it are never inside an `if`
    /// (`CLAUDE.md`).
    var body: some View {
        if !reactions.isEmpty {
            bubble
        }
    }

    /// Every reaction is the person's own: the whole tapback is blue, as
    /// your own tapback is in Messages, rather than a blue chip in gray.
    private var allMine: Bool {
        reactions.allSatisfy(\.includesMe)
    }

    private var bubble: some View {
        let visible = reactions.prefix(Self.shown)
        let hidden = reactions.count - visible.count
        return HStack(spacing: 2) {
            ForEach(Array(visible), id: \.key) { reaction in
                chip(reaction)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(allMine ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 3)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: Self.height)
        // Blue when all of it is yours; otherwise a gray that hides what it
        // covers in either appearance, the window's background with a
        // tertiary fill over it. The ring is the same outline a little
        // larger, filled with the background behind it: a stroke would draw
        // the tail's edge inside the bubble.
        .background {
            ZStack {
                ReactionTapbackShape(isMine: isMine).fill(.background).padding(-Self.ring)
                if allMine {
                    ReactionTapbackShape(isMine: isMine).fill(MessageBubbleLayout.ownFill)
                } else {
                    ReactionTapbackShape(isMine: isMine).fill(.tertiary)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reactions")
    }

    @ViewBuilder private func chip(_ reaction: Reaction) -> some View {
        let label = ReactionDisplay.accessibilityLabel(for: reaction)
        // A chip of its own only where the tapback mixes yours and others'.
        let ownChip = reaction.includesMe && !allMine
        let content = ReactionCapsuleContent(
            reaction: reaction, loadImage: loadImage, showsSingleCount: false
        )
        .font(.callout)
        .foregroundStyle(reaction.includesMe ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 5)
        .frame(height: Self.height - 6)
        .background(
            ownChip ? AnyShapeStyle(MessageBubbleLayout.ownFill) : AnyShapeStyle(.clear), in: Capsule()
        )
        .contentShape(Capsule())
        if let toggle {
            Button { toggle(reaction.choice, !reaction.includesMe) } label: { content }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
                .accessibilityAddTraits(reaction.includesMe ? .isSelected : [])
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}

/// The tapback's outline: a capsule, and a small round tail at its foot on
/// the side over the message. One circle, joined to the capsule: a second,
/// loose one drew as a stray dot on the message's edge (rendered).
struct ReactionTapbackShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        // Sized from the rectangle, so the ring's larger copy (the same
        // shape in a padded rectangle) grows its tail too.
        let tail = rect.height * 0.3
        // Below the leading end of someone else's tapback, below the
        // trailing end of yours: the ends over the message.
        let center = isMine ? rect.maxX - rect.height / 2 + 2 : rect.minX + rect.height / 2 - 2
        path.addEllipse(in: CGRect(x: center - tail / 2, y: rect.maxY - tail / 2, width: tail, height: tail))
        return path
    }
}

/// One emoji and its count. A custom emoji shows its picture once loaded,
/// and its `:shortcode:` before that, without a loader, or when the bytes
/// do not decode (reactions spec §4.1, §5): a failure has no other sign.
struct ReactionCapsuleContent: View {
    let reaction: Reaction
    var loadImage: ((CustomEmojiRef) async throws -> Data)?
    /// Whether a count of one is drawn; a tapback shows only counts above one.
    var showsSingleCount = true
    @State private var image: CGImage?

    /// `image` is for a render harness, which cannot run `.task`.
    init(
        reaction: Reaction,
        loadImage: ((CustomEmojiRef) async throws -> Data)? = nil,
        showsSingleCount: Bool = true,
        image: CGImage? = nil
    ) {
        self.reaction = reaction
        self.loadImage = loadImage
        self.showsSingleCount = showsSingleCount
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
            if showsSingleCount || reaction.count > 1 {
                Text("\(reaction.count)").monospacedDigit()
            }
        }
        .task(id: ReactionDisplay.imageTaskKey(for: reaction, canLoad: loadImage != nil)) {
            guard let loadImage, image == nil,
                  let emoji = ReactionDisplay.imageRequest(for: reaction, canLoad: true)
            else { return }
            image = await (try? loadImage(emoji)).flatMap(ReactionDisplay.image(from:))
        }
    }
}
