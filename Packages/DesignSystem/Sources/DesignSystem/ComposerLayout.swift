import SwiftUI

/// The composer's measurements, read off Messages on macOS 26 at 2x (session
/// 59): a 30pt field, round buttons as tall as one line of it, about 9.5pt
/// between them, 10pt to the window's sides, corners half of one line, and the
/// buttons on the field's bottom edge as it grows. The field here is 31pt, a
/// point taller on the owner's ask (session 20).
enum ComposerLayout {
    /// One line of the field, and the diameter of the buttons beside it. A
    /// button taller than the line made the row taller: the conversation's
    /// composer, with its paperclip, was 4pt taller than the thread's.
    static let lineHeight: CGFloat = 31

    /// Between the buttons and the field, and to the window's sides.
    static let spacing: CGFloat = 10

    /// A capsule at one line, and straight sides beyond it. Six lines in a
    /// capsule ran into its ends, which curve through half its height.
    static let fieldShape = RoundedRectangle(cornerRadius: lineHeight / 2, style: .continuous)

    /// Each checked by `ComposerLayoutTests` (`CLAUDE.md`: an SF Symbol name is
    /// an unchecked string). The emoji face is Messages' filled one, and on
    /// macOS 26 that is `face.smiling`: `.inverse` and `.fill` both draw an
    /// outline, measured by drawing each (session 59).
    static let attachSymbol = "plus"
    static let emojiSymbol = "face.smiling"
    static let dictationSymbol = "waveform"
    static let saveSymbol = "checkmark.circle.fill"

    /// The waveform shows on an empty field, as Messages' does, and text hides
    /// it. Never during an edit: Messages edits in the bubble, with no
    /// waveform, and an emptied edit is one Return would refuse to save.
    static func offersDictation(_ draft: ComposerDraft) -> Bool {
        draft.editing == nil && draft.text.isEmpty
    }
}
