import ChatKit
import SwiftUI

/// The `@` list above the composer (mention composer spec §2): avatar, name,
/// email, presence; the highlighted row is what Return and Tab pick.
///
/// It behaves as a menu does: one highlight, which the arrow keys and the
/// pointer both move, drawn in the system's selection color with the row's
/// text made prominent on it. The keyboard stays in the field, so VoiceOver
/// hears the highlighted person announced, and only VoiceOver: an
/// announcement is speech, and nobody else asked for it.
struct MentionSuggestionList: View {
    let suggestions: [MentionSuggestion]
    let highlighted: Int
    let pick: (MentionSuggestion) -> Void
    /// The pointer entered a row: it becomes the highlighted one.
    var hover: (Int) -> Void = { _ in }
    /// What an outside row says it is not in (`ComposerMentions.place`).
    var place = "space"

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if suggestion.outsideConversation, index > 0, !suggestions[index - 1].outsideConversation {
                    Divider().padding(.vertical, 2)
                }
                let isHighlighted = index == highlighted
                Button { pick(suggestion) } label: {
                    MentionSuggestionRow(suggestion: suggestion, place: place)
                }
                .buttonStyle(.plain)
                .background(
                    isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6)
                )
                .environment(\.backgroundProminence, isHighlighted ? .increased : .standard)
                .accessibilityAddTraits(isHighlighted ? .isSelected : [])
                .onHover { inside in
                    if inside {
                        hover(index)
                    }
                }
            }
        }
        .padding(4)
        .frame(width: 280)
        // A control floating over the transcript, as a menu does: glass, not
        // a material with a drawn shadow.
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .onChange(of: announcement, initial: true) { _, spoken in
            guard voiceOverEnabled, let spoken else { return }
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// What VoiceOver hears for the highlighted row: the row's own two lines.
    private var announcement: String? {
        guard suggestions.indices.contains(highlighted) else { return nil }
        return MentionSuggestionRow.spoken(suggestions[highlighted], place: place)
    }
}

struct MentionSuggestionRow: View {
    /// Verified by `MentionSuggestionListTests`.
    static let allSymbol = "person.3.fill"

    let suggestion: MentionSuggestion
    var place = "space"

    /// The second line: the email; "Not in this space" (or group chat) first
    /// for a directory person; and what `@all` does. An email already shown
    /// as the name is not repeated.
    nonisolated static func detail(of suggestion: MentionSuggestion, place: String = "space") -> String {
        guard let member = suggestion.member else { return "Notify everyone in this space" }
        let email = member.email.flatMap { $0 == suggestion.name ? nil : $0 }
        guard suggestion.outsideConversation else { return email ?? "" }
        return email.map { "Not in this \(place) · \($0)" } ?? "Not in this \(place)"
    }

    /// The title, then the detail when there is one, as VoiceOver reads them.
    nonisolated static func spoken(_ suggestion: MentionSuggestion, place: String = "space") -> String {
        let title = suggestion.member == nil ? "@all" : suggestion.name
        let detail = detail(of: suggestion, place: place)
        return detail.isEmpty ? title : "\(title), \(detail)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if let member = suggestion.member {
                Avatar(member: member.id, directory: [member.id: member], size: 22, presence: member.presence)
            } else {
                Label("Everyone", systemImage: Self.allSymbol)
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(suggestion.member == nil ? "@all" : suggestion.name).lineLimit(1)
                Text(Self.detail(of: suggestion, place: place))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
