import AppKit

/// About Kibble: the standard panel, with the disclaimer, the license and every
/// third-party notice as its credits.
///
/// The notices are not decoration. Sparkle and GRDB are MIT, Sparkle bundles BSD
/// code, and each of those licenses requires its notice in every copy, binaries
/// included. `project.yml` copies `LICENSE` and `THIRD_PARTY_NOTICES.txt` into the
/// app's resources, `scripts/package.sh` refuses a release without them, and
/// `scripts/test.sh` refuses a resolved dependency the notices do not name.
///
/// The credits are built here rather than left to AppKit's `Credits.rtf` lookup
/// for two reasons. Every run carries a dynamic label colour, so the text follows
/// the appearance instead of depending on how a document's colours are read. And
/// the license texts are hard-wrapped at 80 columns, which the panel's narrow
/// credits view would wrap a second time (`reflowed(_:)`).
public enum AboutPanel {
    static let sourceURL = URL(string: "https://github.com/Entersprite/Kibble")!
    static let claudeCodeURL = URL(string: "https://claude.com/claude-code")!

    /// First in the credits. README's Disclaimer section says the same.
    static let disclaimer = "Kibble is provided as is, without warranty of any kind. "
        + "In no event will its authors be held liable for any damages arising from its use, "
        + "including to your Google account. Google has not approved Kibble, and you use it at your own risk."

    static let trademark = "Google Chat is a trademark of Google LLC. "
        + "Kibble is not affiliated with or endorsed by Google."

    @MainActor
    public static func show(bundle: Bundle = .main) {
        let credits = credits(
            license: text(named: "LICENSE", in: bundle),
            notices: text(named: "THIRD_PARTY_NOTICES.txt", in: bundle)
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The panel's credits. A missing text is said, not skipped: a copy without
    /// its notices should not look complete.
    static func credits(license: String?, notices: String?) -> NSAttributedString {
        let credits = NSMutableAttributedString()
        credits.append(paragraph([(disclaimer, nil)], .lead))
        credits.append(paragraph([(trademark, nil)], .lead))
        credits.append(paragraph(
            [
                ("Kibble is free software under the MIT License. Its source code is at ", nil),
                ("github.com/Entersprite/Kibble", sourceURL),
                (".", nil)
            ],
            .lead
        ))
        credits.append(paragraph(
            [("Written with ", nil), ("Claude Code", claudeCodeURL), (", Anthropic's AI coding agent.", nil)],
            .lead
        ))
        if license == nil || notices == nil {
            credits.append(paragraph(
                [
                    ("This copy of Kibble is missing its license texts. They are at ", nil),
                    ("github.com/Entersprite/Kibble", sourceURL),
                    (".", nil)
                ],
                .lead
            ))
        }
        if let license {
            credits.append(paragraph([("License", nil)], .heading))
            append(reflowed(license), to: credits)
        }
        if let notices {
            // The file opens with its own title, so it needs no heading here.
            append(reflowed(notices), to: credits)
        }
        if credits.string.hasSuffix("\n") {
            credits.deleteCharacters(in: NSRange(location: credits.length - 1, length: 1))
        }
        return credits
    }

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
    }

    /// Plain license text as headings and paragraphs, for a view narrower than
    /// the 80 columns it is wrapped at. Wrapping is not part of a license, so only
    /// the line breaks change and every word stays, in order; the bundled file
    /// itself stays verbatim.
    ///
    /// - A blank line ends a paragraph, and the lines inside one are joined with
    ///   spaces.
    /// - A line of `=` or `-` under a line of text makes that line a heading (the
    ///   notices file's section titles, Sparkle's "EXTERNAL LICENSES"). Any other
    ///   such line is a divider and is dropped.
    /// - A copyright line or a list item starts a new line inside its paragraph,
    ///   so the clauses of a BSD license are not run together.
    static func reflowed(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lines: [String] = []
        func flush() {
            guard !lines.isEmpty else {
                return
            }
            blocks.append(.paragraph(joined(lines)))
            lines = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flush()
            } else if isRule(line) {
                let title = lines.popLast()
                flush()
                if let title {
                    blocks.append(.heading(title))
                }
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 2 && (line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" })
    }

    private static func joined(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if !result.isEmpty {
                // U+2028 breaks the line without ending the paragraph.
                result += startsOwnLine(line) ? "\u{2028}" : " "
            }
            result += line
        }
        return result
    }

    private static func startsOwnLine(_ line: String) -> Bool {
        line.hasPrefix("Copyright") || line.hasPrefix("©")
            || line.range(of: #"^(\d+\.|\([a-z0-9]+\)|[-*•])\s"#, options: .regularExpression) != nil
    }

    private static func append(_ blocks: [Block], to credits: NSMutableAttributedString) {
        for block in blocks {
            switch block {
            case let .heading(text):
                credits.append(paragraph([(text, nil)], .heading))
            case let .paragraph(text):
                credits.append(paragraph([(text, nil)], .body))
            }
        }
    }

    enum Style {
        /// The disclaimer and the lines about Kibble, centred like the rest of
        /// the panel.
        case lead
        case heading
        /// License text.
        case body
    }

    private static func paragraph(_ runs: [(String, URL?)], _ style: Style) -> NSAttributedString {
        let paragraph = NSMutableAttributedString()
        for (text, link) in runs {
            var attributes = attributes(style)
            if let link {
                attributes[.link] = link
            }
            paragraph.append(NSAttributedString(string: text, attributes: attributes))
        }
        paragraph.append(NSAttributedString(string: "\n", attributes: attributes(style)))
        return paragraph
    }

    private static func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        let small = NSFont.smallSystemFontSize
        let font: NSFont
        let color: NSColor
        switch style {
        case .lead:
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = 6
            font = .systemFont(ofSize: small)
            color = .labelColor
        case .heading:
            paragraphStyle.paragraphSpacingBefore = 10
            paragraphStyle.paragraphSpacing = 4
            font = .boldSystemFont(ofSize: small)
            color = .labelColor
        case .body:
            paragraphStyle.paragraphSpacing = 4
            font = .systemFont(ofSize: small - 1)
            color = .secondaryLabelColor
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
    }

    private static func text(named name: String, in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
