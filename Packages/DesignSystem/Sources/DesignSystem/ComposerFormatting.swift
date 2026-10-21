import SwiftUI

/// One of the composer's formatting choices: the markup it writes around the
/// selection (`MessageMarkup` reads it back at send), and the title and
/// shortcut both the format button and the menu bar's Format menu show, so
/// the two cannot drift apart.
public enum ComposerFormat: String, CaseIterable, Identifiable, Sendable {
    case bold, italic, underline, strikethrough, code, codeBlock, bulletedList

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .code: "Code"
        case .codeBlock: "Code Block"
        case .bulletedList: "Bulleted List"
        }
    }

    /// Written on both sides of the selection, or before each selected line
    /// for a list (`ComposerTextView.Coordinator.insert`).
    var marker: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        case .underline: "__"
        case .strikethrough: "~~"
        case .code: "`"
        case .codeBlock: "```"
        case .bulletedList: "- "
        }
    }

    /// Cmd-B, Cmd-I and Cmd-U, as in every Mac text editor, and Shift-Cmd-X
    /// for strikethrough, as Google Docs and Slack have it. Code has none: no
    /// Mac convention exists, and Shift-Cmd-C is Show Colors wherever a
    /// Format menu has fonts.
    public var shortcut: KeyboardShortcut? {
        switch self {
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .underline: KeyboardShortcut("u")
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .code, .codeBlock, .bulletedList: nil
        }
    }

    /// The Format menu's items: the styles that apply within a line. A code
    /// block and a list reshape whole lines, and stay on the format button.
    public static let menuBarItems: [ComposerFormat] = [.bold, .italic, .underline, .strikethrough, .code]
}

/// The focused composer's formatting, for the menu bar. `Composer` publishes
/// it with `focusedSceneValue` only while its field has the keyboard and its
/// conversation can be formatted, so the menu's items are disabled
/// everywhere else, as Format items are in a Mac app with no text to format.
///
/// Equal while it comes from the same composer: a new value on every
/// keystroke would rebuild the menu bar's Format menu each time, and `apply`
/// reaches the composer's state wherever it was captured.
public struct ComposerFormatting: Equatable {
    /// The composer it comes from.
    public let id: UUID
    /// Writes the markup around the field's selection, as one undoable step.
    public let apply: @MainActor (ComposerFormat) -> Void

    public init(id: UUID, apply: @escaping @MainActor (ComposerFormat) -> Void) {
        self.id = id
        self.apply = apply
    }

    public static func == (lhs: ComposerFormatting, rhs: ComposerFormatting) -> Bool {
        lhs.id == rhs.id
    }
}

public extension FocusedValues {
    @Entry var composerFormatting: ComposerFormatting?
}
