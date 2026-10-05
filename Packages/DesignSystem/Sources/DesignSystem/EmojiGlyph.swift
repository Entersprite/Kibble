import CoreGraphics
import SwiftUI

/// An emoji drawn as a picture, for the one place a label reaches a platform
/// control that draws images only: the context menu's palette row
/// (`ControlGroup` + `.palette`). macOS draws a palette cell's image and
/// ignores its title, so a text-only `Button("👍")` was an empty cell that
/// still applied its reaction when clicked (owner's screenshot, session 44).
///
/// Drawn once per emoji and kept for the life of the process: six small
/// images, and a context menu is rebuilt every time it opens.
@MainActor
enum EmojiGlyph {
    /// The square's side, in points: a menu palette cell's icon size.
    static let side: CGFloat = 20
    /// Pixels per point. Two covers every Mac display this app runs on.
    static let scale: CGFloat = 2

    private static var drawn: [String: CGImage] = [:]

    /// `nil` only if drawing fails, which leaves the cell as it was before:
    /// empty but clickable.
    static func image(for emoji: String) -> CGImage? {
        if let hit = drawn[emoji] {
            return hit
        }
        let renderer = ImageRenderer(
            content: Text(emoji)
                .font(.system(size: side * 0.85))
                .frame(width: side, height: side)
        )
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        drawn[emoji] = image
        return image
    }
}
