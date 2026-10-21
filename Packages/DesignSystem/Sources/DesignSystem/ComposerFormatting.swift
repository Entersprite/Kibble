import SwiftUI

/// One of the composer's formatting choices: the style the field draws, and
/// the title and shortcut both the format button and the menu bar's Format
/// menu show, so the two cannot drift apart.
public enum ComposerFormat: String, CaseIterable, Identifiable, Sendable {
    case bold, italic, underline, strikethrough, code, codeBlock, bulletedList

    public var id: Self {
        self
    }

    /// The choices whose styles are in `styles`.
    static func choices(for styles: Set<ComposerDraft.Style>) -> Set<ComposerFormat> {
        Set(allCases.filter { $0.style.map(styles.contains) ?? false })
    }

    /// The style the macOS field draws for this choice; `nil` for a list,
    /// which stays typed `- ` lines.
    public var style: ComposerDraft.Style? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .code: .code
        case .codeBlock: .codeBlock
        case .bulletedList: nil
        }
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

    /// The markup `MessageMarkup` reads at send: what a list writes before
    /// each selected line (`ComposerTextView.Coordinator.prefixLines`), and
    /// what the `TextField` outside macOS, which cannot draw a style, writes
    /// at the caret.
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
/// Equal while it comes from the same composer with the same styles on: a
/// new value on every keystroke would rebuild the menu bar's Format menu
/// each time, and `apply` reaches the composer's state wherever it was
/// captured. The styles change only where the caret or selection meets
/// other formatting.
public struct ComposerFormatting: Equatable {
    /// The composer it comes from.
    public let id: UUID
    /// The styles on at the field's caret or over its whole selection,
    /// which the Format menu checks, as Notes does.
    public let active: Set<ComposerFormat>
    /// Turns the style on or off over the field's selection, as one
    /// undoable step, or for what is typed next.
    public let apply: @MainActor (ComposerFormat) -> Void

    public init(
        id: UUID,
        active: Set<ComposerFormat> = [],
        apply: @escaping @MainActor (ComposerFormat) -> Void
    ) {
        self.id = id
        self.active = active
        self.apply = apply
    }

    public static func == (lhs: ComposerFormatting, rhs: ComposerFormatting) -> Bool {
        lhs.id == rhs.id && lhs.active == rhs.active
    }
}

public extension FocusedValues {
    @Entry var composerFormatting: ComposerFormatting?
}
