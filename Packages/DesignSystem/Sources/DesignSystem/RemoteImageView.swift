import ChatKit
import CoreGraphics
import SwiftUI

enum RemoteImagePhase {
    case loading
    case loaded(CGImage)
    case failed
}

/// Loads one remote picture through the host's loader and hands its phase to
/// `content`, which decides the layout: a card collapses on `.failed`, never
/// says so (links spec §7.3). Runs on every appear, but never refetches a
/// loaded image.
struct RemoteImageView<Content: View>: View {
    let url: URL
    let load: (URL) async throws -> Data
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase = RemoteImagePhase.loading

    var body: some View {
        content(phase)
            .task(id: url) {
                if case .loaded = phase {
                    return
                }
                do {
                    let data = try await load(url)
                    let image = await Task
                        .detached(priority: .userInitiated) { AttachmentLayout.decode(data) }
                        .value
                    guard !Task.isCancelled else { return }
                    phase = image.map(RemoteImagePhase.loaded) ?? .failed
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failed
                }
            }
    }
}
