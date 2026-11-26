import SwiftUI

public extension EnvironmentValues {
    @Entry var openEmbeddedMedia: (@MainActor @Sendable (URL) -> Void)?
}
