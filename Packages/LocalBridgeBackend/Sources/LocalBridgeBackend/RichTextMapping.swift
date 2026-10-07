import ChatKit
import Foundation
import GChatBridgeCore

/// Google's formatted text to `RichText` (links spec §4.3). From
/// `formatted_text_elements` when present, else from `original_text` with
/// its markup stripped. A hyperlink keeps its target only through
/// `CardMapping.target(_:)`. Empty text is `nil`, so a caller can drop it.
/// Which of the two forms apps send is `[Verify]` (`findings.md` §60).
enum RichTextMapping {
    private typealias Element = JAddOnsFormattedText.FormattedTextElement

    static func text(_ formatted: JAddOnsFormattedText) -> RichText? {
        let runs = formatted.formattedTextElements.isEmpty
            ? [RichText.Run(text: plain(formatted.originalText))]
            : formatted.formattedTextElements.compactMap(run)
        let kept = runs.filter { !$0.text.isEmpty }
        return kept.isEmpty ? nil : RichText(runs: kept)
    }

    private static func run(_ element: Element) -> RichText.Run? {
        switch element.element {
        case let .styledText(styled)?:
            styledRun(styled)
        case let .hyperlink(link)?:
            RichText.Run(text: link.text.isEmpty ? link.link : link.text, link: CardMapping.target(link.link))
        case nil:
            nil
        }
    }

    /// `BR` is a line break before the run, as purple writes it.
    private static func styledRun(_ styled: Element.StyledText) -> RichText.Run {
        let styles = Set(styled.styles)
        var text = styled.hasDatetime ? date(styled.datetime) : styled.text
        if styles.contains(.uppercase) {
            text = text.uppercased()
        }
        if styles.contains(.br) {
            text = "\n" + text
        }
        return RichText.Run(
            text: text,
            bold: (styled.hasFontWeight && styled.fontWeight == .bold) || styles.contains(.boldDeprecated),
            italic: styles.contains(.italic),
            underline: styles.contains(.underline),
            strikethrough: styles.contains(.strikethrough)
        )
    }

    /// In this Mac's zone and locale, at mapping time `[Verify]` for a future
    /// bridge server, which would format in its own.
    private static func date(_ value: Element.DateTime) -> String {
        let date = Date(timeIntervalSince1970: Double(value.timeMillis) / 1000)
        return date.formatted(date: .abbreviated, time: value.dateOnly ? .omitted : .shortened)
    }

    /// Tags out, `<br>` to a newline, the common entities decoded.
    static func plain(_ markup: String) -> String {
        markup
            .replacing(#/<br\s*/?>/#.ignoresCase(), with: "\n")
            .replacing(#/<[^>]*>/#, with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
