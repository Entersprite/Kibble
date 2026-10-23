import SwiftUI

/// One presentation session's image port. Identity changes with its cache owner.
public struct SceneImageLoader: Sendable {
    public let id: UUID
    public let load: @MainActor @Sendable (URL) async throws -> Data

    public init(id: UUID, load: @escaping @MainActor @Sendable (URL) async throws -> Data) {
        self.id = id
        self.load = load
    }
}

public extension EnvironmentValues {
    @Entry var sceneImageLoader: SceneImageLoader?
}

struct SceneImage<Content: View, Placeholder: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @Environment(\.sceneImageLoader) private var loader

    var body: some View {
        if let loader {
            let fetch: (URL) async throws -> Data = { try await loader.load($0) }
            RemoteImageView(url: url, load: fetch) { phase in
                if case let .loaded(picture) = phase {
                    content(Image(decorative: picture.first, scale: 1))
                } else {
                    placeholder()
                }
            }
            .id(loader.id)
        } else {
            placeholder()
        }
    }
}
