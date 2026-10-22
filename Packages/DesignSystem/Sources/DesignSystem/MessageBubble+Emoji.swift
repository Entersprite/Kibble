import ChatKit
import SwiftUI

extension MessageBubble {
    var availableReactions: ReactionActions? {
        state.canUseProviderActions ? reactions : nil
    }

    var inlineEmojiLoadKey: CustomEmojiLoadingKey {
        CustomEmojiLoadingKey(
            emoji: (message.content?.customEmoji ?? []).map(\.emoji),
            canLoad: availableReactions?.customImage != nil
        )
    }

    func loadInlineEmoji() async {
        inlineEmojiImages = [:]
        guard !message.isDeleted, let load = availableReactions?.customImage else { return }
        for emoji in Set((message.content?.customEmoji ?? []).prefix(256).map(\.emoji)) {
            let data = try? await load(emoji)
            guard !Task.isCancelled else { return }
            if let data {
                inlineEmojiImages[emoji] = data
            }
        }
    }
}
