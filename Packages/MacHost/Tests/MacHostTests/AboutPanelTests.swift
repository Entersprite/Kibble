import AppKit
import Foundation
import Testing
@testable import MacHost

/// About Kibble's credits: the disclaimer comes first, every notice the app ships
/// is in them, and reflowing a license for the panel changes its line breaks and
/// nothing else.
struct AboutPanelTests {
    /// The repository root, where `LICENSE` and `THIRD_PARTY_NOTICES.txt` live.
    /// The app reads its bundled copies; `scripts/package.sh` checks those are
    /// these files, byte for byte.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MacHostTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MacHost
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()

    static func repositoryText(_ name: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(name), encoding: .utf8)
    }

    /// Words in order, ignoring how they are broken into lines. Divider lines are
    /// left out, because the reflow drops them on purpose.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isDivider(line) {
                words += line.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return words
    }

    static func isDivider(_ line: String) -> Bool {
        guard line.count >= 2 else {
            return false
        }
        return line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" }
    }

    static func words(_ blocks: [AboutPanel.Block]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case let .heading(text), let .paragraph(text):
                text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2028}" }).map(String.init)
            }
        }
    }

    @Test func theDisclaimerComesFirst() {
        let credits = AboutPanel.credits(license: "MIT License", notices: "Notices").string
        #expect(credits.hasPrefix(AboutPanel.disclaimer))
        #expect(credits.contains(AboutPanel.trademark))
        #expect(credits.contains("MIT License"))
    }

    @Test func theSourceAndClaudeCodeAreLinks() {
        let credits = AboutPanel.credits(license: "MIT License", notices: "Notices")
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL {
                links.append(url)
            }
        }
        #expect(links.contains(AboutPanel.sourceURL))
        #expect(links.contains(AboutPanel.claudeCodeURL))
    }

    /// A fixed colour, or none (which draws black), would be unreadable in Dark
    /// Mode. Every character carries one of the two dynamic label colours.
    @Test func everyRunFollowsTheAppearance() throws {
        let credits = try AboutPanel.credits(
            license: Self.repositoryText("LICENSE"),
            notices: Self.repositoryText("THIRD_PARTY_NOTICES.txt")
        )
        var uncoloured = 0
        credits.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: credits.length)
        ) { value, range, _ in
            let color = value as? NSColor
            if color != NSColor.labelColor, color != NSColor.secondaryLabelColor {
                uncoloured += range.length
            }
        }
        #expect(credits.length > 10000)
        #expect(uncoloured == 0)
    }

    /// Either text missing is enough: a copy with its license and no notices is
    /// the case that matters most, and must not look complete.
    @Test(arguments: [(nil, nil), ("MIT License", nil), (nil, "Notices")] as [(String?, String?)])
    func aCopyWithoutItsTextsSaysSo(license: String?, notices: String?) {
        let credits = AboutPanel.credits(license: license, notices: notices).string
        #expect(credits.hasPrefix(AboutPanel.disclaimer))
        #expect(credits.contains("missing its license texts"))
    }

    @Test func aCompleteCopySaysNothingIsMissing() {
        #expect(!AboutPanel.credits(license: "MIT License", notices: "Notices").string
            .contains("missing its license texts"))
    }

    @Test func linesInAParagraphAreJoined() {
        let text = "Permission is hereby granted,\n  free of charge,\nto any person.\n\nSecond paragraph."
        #expect(AboutPanel.reflowed(text) == [
            .paragraph("Permission is hereby granted, free of charge, to any person."),
            .paragraph("Second paragraph.")
        ])
    }

    @Test func anUnderlinedLineIsAHeadingAndOtherDividersAreDropped() {
        let text = "=================\nEXTERNAL LICENSES\n=================\n\nbsdiff\n\n--\n\nsais"
        #expect(AboutPanel.reflowed(text) == [
            .heading("EXTERNAL LICENSES"),
            .paragraph("bsdiff"),
            .paragraph("sais")
        ])
    }

    @Test func copyrightLinesAndListItemsStartTheirOwnLine() {
        let text = """
        Copyright (c) 2006 One.
        Copyright (c) 2009 Two.
        All rights reserved.

        are met:
        1. Redistributions of source code must retain the above copyright
           notice.
        2. Redistributions in binary form
        (a) You must give
        """
        #expect(AboutPanel.reflowed(text) == [
            .paragraph("Copyright (c) 2006 One.\u{2028}Copyright (c) 2009 Two. All rights reserved."),
            .paragraph(
                "are met:\u{2028}1. Redistributions of source code must retain the above copyright notice."
                    + "\u{2028}2. Redistributions in binary form\u{2028}(a) You must give"
            )
        ])
    }

    /// The shipped files, reflowed: every word kept in order, no divider left,
    /// and every section a heading.
    @Test(arguments: ["LICENSE", "THIRD_PARTY_NOTICES.txt"])
    func reflowingAShippedFileKeepsEveryWord(name: String) throws {
        let text = try Self.repositoryText(name)
        let blocks = AboutPanel.reflowed(text)
        let original = Self.words(text)
        #expect(original.count > 100)
        #expect(Self.words(blocks) == original)
        for case let .paragraph(paragraph) in blocks {
            #expect(!paragraph.contains("\n"))
        }
    }

    /// Versions are left out on purpose: `scripts/test.sh` already holds the
    /// notices to the resolved versions, and a bump should not need this test too.
    @Test func everyNoticeIsAHeading() throws {
        let blocks = try AboutPanel.reflowed(Self.repositoryText("THIRD_PARTY_NOTICES.txt"))
        let headings = blocks.compactMap { block -> String? in
            if case let .heading(text) = block {
                text
            } else {
                nil
            }
        }
        let expected = [
            "Third-party notices for Kibble",
            "Sparkle ",
            "EXTERNAL LICENSES",
            "GRDB.swift ",
            "swift-protobuf ",
            "Unicode emoji data ",
            "hangups",
            "googlechat.proto"
        ]
        #expect(headings.count == expected.count)
        for (heading, prefix) in zip(headings, expected) {
            #expect(heading.hasPrefix(prefix))
        }
    }
}
