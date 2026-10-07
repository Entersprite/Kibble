import AppKit

/// The legal texts Kibble shows: About Kibble's three short lines, and the three
/// documents the Help menu opens (`HelpWindows`): the disclaimer, Kibble's license
/// and the third-party notices.
///
/// The notices are not decoration. Sparkle and GRDB are MIT, Sparkle bundles BSD
/// code, and each of those licenses requires its notice in every copy, binaries
/// included. `project.yml` copies `LICENSE` and `THIRD_PARTY_NOTICES.txt` into the
/// app's resources, `scripts/package.sh` refuses a release without them, and
/// `scripts/test.sh` refuses a resolved dependency the notices do not name.
///
/// Every run carries a dynamic label color, so the text follows the appearance
/// instead of depending on how a document's colors are read. The license texts
/// are hard-wrapped at 80 columns, so they are reflowed (`reflowed(_:)`) and wrap
/// to whatever width their window has.
enum LegalText {
    static let sourceURL = URL(string: "https://github.com/Entersprite/Kibble")!
    static let licenseFile = "LICENSE"
    static let noticesFile = "THIRD_PARTY_NOTICES.txt"

    /// Help › Disclaimer. README's Disclaimer section says the same.
    static let disclaimer = "Kibble is provided as is, without warranty of any kind. "
        + "In no event will its authors be held liable for any damages arising from its use, "
        + "including to your Google account. Google has not approved Kibble, and you use it at your own risk."

    static let trademark = "Google Chat is a trademark of Google LLC. "
        + "Kibble is not affiliated with or endorsed by Google."

    /// About Kibble's credits. Three short lines; everything longer is in the
    /// Help menu, and the last line says so.
    static func aboutCredits() -> NSAttributedString {
        document([
            paragraph([("Kibble is free and open-source software under the MIT License.", nil)], .panel),
            paragraph([("Source code: ", nil), ("github.com/Entersprite/Kibble", sourceURL)], .panel),
            paragraph([("The license, acknowledgments and disclaimer are in the Help menu.", nil)], .panel)
        ])
    }

    static func disclaimerDocument() -> NSAttributedString {
        document([paragraph([(disclaimer, nil)], .text), paragraph([(trademark, nil)], .text)])
    }

    /// Kibble's own license. A missing text is said, not skipped: a copy without
    /// it should not look complete.
    static func licenseDocument(_ license: String?) -> NSAttributedString {
        guard let license else {
            return document([missing("its license")])
        }
        return document(paragraphs(reflowed(license)))
    }

    /// The third-party notices. The file opens with its own title.
    static func acknowledgmentsDocument(_ notices: String?) -> NSAttributedString {
        guard let notices else {
            return document([missing("its third-party notices")])
        }
        return document(paragraphs(reflowed(notices)))
    }

    static func text(named name: String, in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
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

    private static func missing(_ what: String) -> NSAttributedString {
        paragraph(
            [
                ("This copy of Kibble is missing \(what). It is at ", nil),
                ("github.com/Entersprite/Kibble", sourceURL),
                (".", nil)
            ],
            .text
        )
    }

    private static func paragraphs(_ blocks: [Block]) -> [NSAttributedString] {
        blocks.map { block in
            switch block {
            case let .heading(text):
                paragraph([(text, nil)], .heading)
            case let .paragraph(text):
                paragraph([(text, nil)], .license)
            }
        }
    }

    /// The paragraphs joined, without the last one's line break.
    private static func document(_ paragraphs: [NSAttributedString]) -> NSAttributedString {
        let document = NSMutableAttributedString()
        paragraphs.forEach(document.append)
        if document.string.hasSuffix("\n") {
            document.deleteCharacters(in: NSRange(location: document.length - 1, length: 1))
        }
        return document
    }

    enum Style {
        /// About Kibble's lines, small and centered like the rest of the panel.
        case panel
        /// A Help window's own words: the disclaimer, a missing-text notice.
        case text
        case heading
        /// License text, reflowed.
        case license
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
        let regular = NSFont.systemFontSize
        let font: NSFont
        let color: NSColor
        switch style {
        case .panel:
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = 4
            font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            color = .labelColor
        case .text:
            paragraphStyle.paragraphSpacing = 10
            font = .systemFont(ofSize: regular)
            color = .labelColor
        case .heading:
            paragraphStyle.paragraphSpacingBefore = 12
            paragraphStyle.paragraphSpacing = 6
            font = .boldSystemFont(ofSize: regular)
            color = .labelColor
        case .license:
            paragraphStyle.paragraphSpacing = 6
            font = .systemFont(ofSize: regular - 1)
            color = .secondaryLabelColor
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
    }
}
