import SwiftUI

/// The transcript while an open chat with nothing saved waits for its first
/// page: loading, not "No messages". Drawn after a moment, so a page that
/// arrives quickly shows no flash of progress.
struct TranscriptLoading: View {
    static let delay: Duration = .milliseconds(400)

    @State private var shown = false

    var body: some View {
        ProgressView()
            .opacity(shown ? 1 : 0)
            .accessibilityLabel("Loading messages")
            .accessibilityHidden(!shown)
            .task {
                try? await Task.sleep(for: Self.delay)
                shown = !Task.isCancelled
            }
    }
}
