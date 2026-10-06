import ChatKit
import Foundation

public extension ComposedMessage {
    /// The same message with `mode` on the mentions of `people`, and no other
    /// change: the confirmation's answer (mention non-members spec §2).
    func settingMode(_ mode: Mention.Mode, for people: [Member.ID]) -> ComposedMessage {
        var copy = self
        copy.mentions = mentions.map { mention in
            guard case let .user(id) = mention.target, people.contains(id) else { return mention }
            var changed = mention
            changed.mode = mode
            return changed
        }
        return copy
    }

    /// Each person's name as their token reads, in the message's order and
    /// once each, for the confirmation's title.
    func names(of people: [Member.ID]) -> [String] {
        let units = text as NSString
        var seen: Set<Member.ID> = []
        return mentions.compactMap { mention in
            guard case let .user(id) = mention.target, people.contains(id), seen.insert(id).inserted,
                  mention.length > 1, mention.start + mention.length <= units.length else { return nil }
            return units.substring(with: NSRange(location: mention.start + 1, length: mention.length - 1))
        }
    }
}
