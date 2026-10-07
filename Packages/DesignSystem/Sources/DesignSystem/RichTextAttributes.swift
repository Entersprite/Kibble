import ChatKit
import Foundation
import SwiftUI

/// An app card's text as an `AttributedString` for SwiftUI's `Text`
/// (links spec §7.4). Bold, italic and strikethrough are inline intents,
/// which `Text` draws in the surrounding font; a link is set only when
/// `LinkPolicy` would open it.
enum RichTextAttributes {
    static func attributed(_ text: RichText) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold {
                intent.insert(.stronglyEmphasized)
            }
            if run.italic {
                intent.insert(.emphasized)
            }
            if run.strikethrough {
                intent.insert(.strikethrough)
            }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
            }
            if run.underline {
                piece.underlineStyle = .single
            }
            if let link = run.link, LinkPolicy.canOpen(link) {
                piece.link = link
            }
            result += piece
        }
        return result
    }
}
