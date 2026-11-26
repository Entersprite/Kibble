#if os(macOS)
    import AppKit
    import ChatKit

    enum MessageFormatAttributes {
        static func apply(_ formats: [MessageFormat], text: String, to result: NSMutableAttributedString) {
            for format in formats {
                guard let valid = format.range(in: text) else { continue }
                let range = NSRange(valid, in: text)
                switch format.style {
                case "underline":
                    result.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                case "strikethrough":
                    result.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                case "bold", "italic", "code", "codeBlock":
                    applyFont(format.style, range: range, to: result)
                case "bulletList", "bulletItem":
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = 16
                    paragraph.firstLineHeadIndent = 8
                    result.addAttribute(.paragraphStyle, value: paragraph, range: range)
                default: break
                }
            }
            let bullets = Set(formats.filter { $0.style == "bulletItem" && $0.range(in: text) != nil }
                .map(\.start))
            for start in bullets.sorted(by: >) {
                result.insert(NSAttributedString(string: "• ", attributes: [
                    .font: NSFont.preferredFont(forTextStyle: .body)
                ]), at: start)
            }
        }

        private static func applyFont(_ style: String, range: NSRange, to result: NSMutableAttributedString) {
            var runs: [(NSRange, NSFont)] = []
            result.enumerateAttribute(.font, in: range) { font, span, _ in
                let base = font as? NSFont ?? .preferredFont(forTextStyle: .body)
                let styled: NSFont = switch style {
                case "bold": NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                case "italic": NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                default: .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                }
                runs.append((span, styled))
            }
            for (span, font) in runs {
                result.addAttribute(.font, value: font, range: span)
            }
        }
    }
#endif
