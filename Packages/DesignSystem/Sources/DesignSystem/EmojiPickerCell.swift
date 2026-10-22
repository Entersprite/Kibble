import ChatKit
import SwiftUI

/// Includes availability so a newly usable loader restarts a previously
/// read-only placeholder, even when its emoji reference did not change.
struct CustomEmojiLoadingKey: Hashable {
    let emoji: [CustomEmojiRef]
    let canLoad: Bool
}

/// One cell: the emoji or custom picture, with the current choice callbacks.
struct EmojiPickerCell: View {
    let item: EmojiPickerItem
    /// Whether choosing it adds; `false` removes the person's own.
    let adds: Bool
    let isHighlighted: Bool
    let loadImage: ((CustomEmojiRef) async throws -> Data)?
    let onHover: (Bool) -> Void
    let onChoose: (ReactionChoice, Bool) -> Void

    var body: some View {
        Button { onChoose(item.choice, adds) } label: { label }
            .buttonStyle(.plain)
            .focusable(false)
            .background(AccountPanelHighlight(isOn: isHighlighted, cornerRadius: 6))
            .onHover(perform: onHover)
            .help(item.name)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var label: some View {
        Group {
            if let emoji = item.choice.customEmoji {
                CustomEmojiCell(emoji: emoji, load: loadImage)
            } else {
                Text(item.choice.emoji).font(.system(size: 22))
            }
        }
        .frame(minWidth: 28, maxWidth: 32, minHeight: 32, maxHeight: 32)
        .contentShape(Rectangle())
    }
}

/// A custom emoji's picture once it loads; its shortcode before that, without
/// a loader, or when the bytes do not decode.
struct CustomEmojiCell: View {
    let emoji: CustomEmojiRef
    let load: ((CustomEmojiRef) async throws -> Data)?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text(emoji.displayText))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Text(emoji.displayText)
                    .font(.system(size: 8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
        }
        .task(id: CustomEmojiLoadingKey(emoji: [emoji], canLoad: load != nil)) {
            image = nil
            guard let load else { return }
            let loaded = await (try? load(emoji)).flatMap(ReactionDisplay.image(from:))
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
