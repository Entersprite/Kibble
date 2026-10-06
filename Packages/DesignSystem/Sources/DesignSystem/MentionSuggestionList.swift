import ChatKit
import SwiftUI

/// The `@` list above the composer (mention composer spec §2): avatar, name,
/// email, presence; the highlighted row is what Return and Tab pick.
struct MentionSuggestionList: View {
    let suggestions: [MentionSuggestion]
    let highlighted: Int
    let pick: (MentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    MentionSuggestionRow(suggestion: suggestion)
                }
                .buttonStyle(.plain)
                .background(
                    index == highlighted ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: .rect(cornerRadius: 6)
                )
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

struct MentionSuggestionRow: View {
    /// Verified by `MentionSuggestionListTests`.
    static let allSymbol = "person.3.fill"

    let suggestion: MentionSuggestion

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
                Text(suggestion.member?.email ?? "Notify everyone in this space")
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
