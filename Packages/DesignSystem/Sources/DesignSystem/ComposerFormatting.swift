import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// One of the composer's formatting choices: the style the field draws, and
/// the title and shortcut the field's Format submenu shows and its keyboard
/// answers (`ComposerTextView`), so the two cannot drift apart.
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

    /// The choices with a shortcut, which the field answers itself while it
    /// has the keyboard; no menu bar command may take one of their keys
    /// (`MenuBarShortcuts.all`).
    public static let keyed: [ComposerFormat] = allCases.filter { $0.shortcut != nil }

    /// The Format submenu's picture (checked by `ComposerLayoutTests`).
    static let menuSymbol = "textformat"
}

#if os(macOS)
    extension ComposerFormat {
        /// The shortcut as an `NSMenuItem` shows it; empty for none.
        var keyEquivalent: String {
            shortcut.map { String($0.key.character) } ?? ""
        }

        var keyEquivalentModifiers: NSEvent.ModifierFlags {
            guard let modifiers = shortcut?.modifiers else { return [] }
            let pairs: [(EventModifiers, NSEvent.ModifierFlags)] = [
                (.command, .command), (.shift, .shift), (.option, .option), (.control, .control)
            ]
            return pairs.reduce(into: []) { flags, pair in
                if modifiers.contains(pair.0) {
                    flags.insert(pair.1)
                }
            }
        }

        /// The choice a key press asks for: its key, ignoring case, with
        /// exactly its modifiers; `nil` for any other press.
        static func choice(key: String?, modifiers: NSEvent.ModifierFlags) -> ComposerFormat? {
            guard let key = key?.lowercased() else { return nil }
            let pressed = modifiers.intersection([.command, .shift, .option, .control])
            return keyed.first { $0.keyEquivalent == key && $0.keyEquivalentModifiers == pressed }
        }
    }
#endif
