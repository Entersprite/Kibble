import ChatKit
import CoreGraphics
import SwiftUI

enum RemoteImagePhase {
    case loading
    case loaded(CGImage)
    case failed
}

/// What a remote picture shows for a URL, given the last load and the last
/// failure. Each counts only for its own URL, so a view reused for a new URL -
/// an app card updated in place - shows the new picture, never the old one
/// (review finding 2).
struct RemoteImageState {
    var loaded: (url: URL, image: CGImage)?
    var failed: URL?

    func phase(for url: URL) -> RemoteImagePhase {
        if let loaded, loaded.url == url {
            return .loaded(loaded.image)
        }
        return failed == url ? .failed : .loading
    }
}

/// Loads one remote picture through the host's loader and hands its phase to
/// `content`, which decides the layout: a card collapses on `.failed`, never
/// says so (links spec §7.3). Runs on every appear and every new URL, but never
/// refetches a picture already loaded for this URL.
struct RemoteImageView<Content: View>: View {
    let url: URL
    let load: (URL) async throws -> Data
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var state = RemoteImageState()

    var body: some View {
        content(state.phase(for: url))
            .task(id: url) {
                if case .loaded = state.phase(for: url) {
                    return
                }
                let requested = url
                do {
                    let data = try await load(requested)
                    let image = await Task
                        .detached(priority: .userInitiated) { AttachmentLayout.decode(data) }
                        .value
                    guard !Task.isCancelled else { return }
                    if let image {
                        state.loaded = (requested, image)
                    } else {
                        state.failed = requested
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    state.failed = requested
                }
            }
    }
}
