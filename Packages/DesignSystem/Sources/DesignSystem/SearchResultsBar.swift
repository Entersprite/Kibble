import ChatKit
import SwiftUI

/// The results bar's words (search spec §1.4).
enum SearchBarText {
    static func position(_ bar: SearchBarScene) -> String {
        if bar.isOpening {
            return "Loading older messages…"
        }
        let position = "\(bar.index + 1) of \(bar.count)\(bar.hasMore ? "+" : "")"
        if bar.pageFailed {
            return "\(position) · Couldn't load more results"
        }
        switch bar.unreachable {
        case .tooFarBack?: return "\(position) · Couldn't open this message"
        case .notInSidebar?: return "\(position) · Can't open this message here"
        case nil: return position
        }
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
    /// `request` is the highlight with its open's generation, so the same
    /// message opened again is marked again.
    static func shouldMark(
        _ request: TranscriptScroll.Request?, in messages: [Message], marked: TranscriptScroll.Request?
    ) -> Bool {
        guard let request, request != marked else { return false }
        return messages.contains { $0.id == request.id }
    }

    /// The mark's lifecycle: turn on, wait, turn off - unless the wait is
    /// canceled (a second ⌘G landed within the two seconds) or `isStillMarked`
    /// says this mark was superseded before the wait ended.
    ///
    /// `sleep`, `isStillMarked`, `on` and `off` are injected so a test can
    /// drive every branch without hosting a view or waiting two real seconds.
    /// This exists because `try? await Task.sleep(...)` in `MessageList`
    /// swallowed `CancellationError`, so a task a newer trigger had already
    /// canceled still ran `off()` and could switch the *newer* mark back off.
    @MainActor
    static func fade(
        on: () -> Void,
        sleep: () async throws -> Void,
        isStillMarked: () -> Bool,
        off: () -> Void
    ) async {
        on()
        do {
            try await sleep()
        } catch {
            // Canceled: a newer trigger is already running its own mark.
            // Falling through to `off()` here is exactly the bug this
            // function exists to not have.
            return
        }
        guard isStillMarked() else { return }
        off()
    }
}
