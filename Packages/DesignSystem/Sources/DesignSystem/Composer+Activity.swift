import ChatKit
import SwiftUI

extension Composer {
    func finish(_ message: ComposedMessage) {
        if ComposerSendGate.clears(draft: draft.composed(formatting: allowsFormatting), sent: message) {
            draft.clear()
        }
        if let sendHere = mentions?.sendHere {
            sendHere(message)
        } else {
            send(message)
        }
    }

    var trimmed: String {
        draft.composed(formatting: allowsFormatting).text
    }

    func insert(_ text: String) {
        #if os(macOS)
            insertion = ComposerInsertion(text: text)
        #else
            draft.replace(location: draft.caret, length: 0, with: text)
        #endif
    }

    #if os(macOS)
        /// The styles on at the field's selection, kept for the Format menu's
        /// checkmarks only when they change, so the menu is not rebuilt for
        /// every keystroke or caret move.
        func noteStyles(_ styles: Set<ComposerDraft.Style>) {
            let formats = ComposerFormat.choices(for: styles)
            if formats != activeFormats {
                activeFormats = formats
            }
        }

        /// Pasted files and pictures, while this composer can stage them:
        /// the host can upload, and no edit is in progress.
        var pasteActions: ComposerPaste? {
            guard let attachmentActions, draft.editing == nil else { return nil }
            return ComposerPaste(files: attachmentActions.stage, image: attachmentActions.stageImage)
        }
    #endif

    /// From the format button or the Format menu. On macOS the field draws
    /// the style itself: it goes on or off over the selection, or for what
    /// is typed next, through the field as one step Cmd-Z takes back
    /// (`ComposerTextView.Coordinator.toggle`), and a list's `- ` goes
    /// before each selected line. The `TextField` elsewhere cannot draw a
    /// style, so there the markup goes in at the caret.
    func format(_ style: ComposerFormat) {
        #if os(macOS)
            if let toggle = style.style {
                insertion = ComposerInsertion(toggle: toggle)
            } else {
                insertion = ComposerInsertion(linePrefix: style.marker)
            }
        #else
            let marker = style.marker
            draft.replace(
                location: draft.caret,
                length: 0,
                with: style == .bulletedList ? marker : marker + marker
            )
        #endif
    }
}

struct ComposerActivityReporting: ViewModifier {
    let empty: Bool
    let editing: Bool
    let report: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .onChange(of: empty) { _, isEmpty in
                if isEmpty {
                    report?(false)
                }
            }
            .onChange(of: editing) { _, isEditing in
                if isEditing {
                    report?(false)
                }
            }
    }
}
