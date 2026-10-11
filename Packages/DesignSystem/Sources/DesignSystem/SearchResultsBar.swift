import ChatKit
import SwiftUI

/// The results bar's words (search spec §1.4).
enum SearchBarText {
    static func position(_ bar: SearchBarScene) -> String {
        if bar.isOpening {
            return "Loading older messages…"
        }
        if bar.unreachable {
            return "Too far back to open here"
        }
        return "\(bar.index + 1) of \(bar.count)\(bar.hasMore ? "+" : "")"
    }
}

/// The bar under the toolbar: the search, where you are in it, ‹ › to step,
/// Show All to reopen the overlay, ✕ to end. Its own row in the content
/// column, under `StatusStrip`, so it never covers a message.
struct SearchResultsBar: View {
    let bar: SearchBarScene
    let state: ChatSceneState
    let actions: SearchActions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(SearchPresentation.summary(
                of: bar.query, directory: state.directory, conversations: state.conversations, me: state.me
            ))
            .lineLimit(1)
            .truncationMode(.middle)
            if bar.isOpening {
                ProgressView().controlSize(.small)
            }
            Text(SearchBarText.position(bar))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { actions.step(-1) } label: {
                Label("Previous Result", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(bar.index == 0)
            .help("Previous result (⇧⌘G)")
            Button { actions.step(1) } label: {
                Label("Next Result", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(bar.index >= bar.count - 1 && !bar.hasMore)
            .help("Next result (⌘G)")
            Button("Show All", action: actions.show)
            Button(action: actions.end) {
                Label("End Search", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .help("End search")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// When the transcript marks a message a search opened: once, when it is
/// loaded. Pure, like `TranscriptScroll`.
enum TranscriptMark {
    static func shouldMark(_ id: Message.ID?, in messages: [Message], marked: Message.ID?) -> Bool {
        guard let id, id != marked else { return false }
        return messages.contains { $0.id == id }
    }
}
