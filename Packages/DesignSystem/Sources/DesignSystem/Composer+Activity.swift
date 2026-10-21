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
        /// Pasted files and pictures, while this composer can stage them:
        /// the host can upload, and no edit is in progress.
        var pasteActions: ComposerPaste? {
            guard let attachmentActions, draft.editing == nil else { return nil }
            return ComposerPaste(files: attachmentActions.stage, image: attachmentActions.stageImage)
        }
    #endif
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
