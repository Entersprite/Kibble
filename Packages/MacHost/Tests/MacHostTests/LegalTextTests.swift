import AppKit
import Foundation
import Testing
@testable import MacHost

/// The legal texts: About Kibble stays short, the Help menu's documents carry
/// the rest, and reflowing a license changes its line breaks and nothing else.
struct LegalTextTests {
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

    static func words(_ blocks: [LegalText.Block]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case let .heading(text), let .paragraph(text):
                text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2028}" }).map(String.init)
            }
        }
    }

    static func links(in text: NSAttributedString) -> [URL] {
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL {
                links.append(url)
            }
        }
        return links
    }

    /// The owner's rule: About Kibble keeps a few short lines about the MIT
    /// License, and the disclaimer and the license texts live in the Help menu.
    @Test func aboutKibbleIsAFewShortLinesAboutTheLicense() {
        let credits = LegalText.aboutCredits()
        let lines = credits.string.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.count <= 80 })
        #expect(credits.string.contains("MIT License"))
        #expect(credits.string.contains("Help menu"))
        #expect(!credits.string.contains(LegalText.disclaimer))
        #expect(!credits.string.contains("Permission is hereby granted"))
        #expect(Self.links(in: credits) == [LegalText.sourceURL])
    }

    @Test func theDisclaimerWindowSaysItAll() {
        let text = LegalText.disclaimerDocument().string
        #expect(text.hasPrefix(LegalText.disclaimer))
        #expect(text.contains(LegalText.trademark))
    }

    /// A fixed color, or none (which draws black), would be unreadable in Dark
    /// Mode. Every character carries one of the two dynamic label colors.
    @Test func everyRunFollowsTheAppearance() throws {
        let documents = try [
            LegalText.aboutCredits(),
            LegalText.disclaimerDocument(),
            LegalText.licenseDocument(Self.repositoryText(LegalText.licenseFile)),
            LegalText.acknowledgmentsDocument(Self.repositoryText(LegalText.noticesFile)),
            LegalText.licenseDocument(nil)
        ]
        for document in documents {
            var uncolored = 0
            document.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: document.length)
            ) { value, range, _ in
                let color = value as? NSColor
                if color != NSColor.labelColor, color != NSColor.secondaryLabelColor {
                    uncolored += range.length
                }
            }
            #expect(document.length > 0)
            #expect(uncolored == 0)
        }
    }

    @Test func aMissingTextIsSaidNotSkipped() {
        let license = LegalText.licenseDocument(nil)
        let notices = LegalText.acknowledgmentsDocument(nil)
        #expect(license.string.contains("missing its license"))
        #expect(notices.string.contains("missing its third-party notices"))
        #expect(Self.links(in: license) == [LegalText.sourceURL])
        #expect(!LegalText.licenseDocument("MIT License").string.contains("missing"))
        #expect(!LegalText.acknowledgmentsDocument("Notices").string.contains("missing"))
    }

    /// A bundle holding the two files with different words in each, so a window
    /// that read the other's file would show the wrong one. A bundle with neither
    /// file could not tell: both windows would say "missing" either way.
    @MainActor
    @Test func eachWindowReadsItsOwnFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegalTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Kibble license words".write(
            to: folder.appendingPathComponent(LegalText.licenseFile), atomically: true, encoding: .utf8
        )
        try "Third-party notice words".write(
            to: folder.appendingPathComponent(LegalText.noticesFile), atomically: true, encoding: .utf8
        )
        let bundle = try #require(Bundle(url: folder))

        #expect(HelpWindows.content(.license, bundle: bundle).string == "Kibble license words")
        #expect(HelpWindows.content(.acknowledgments, bundle: bundle).string == "Third-party notice words")
        #expect(HelpWindows.content(.disclaimer, bundle: bundle).string.hasPrefix(LegalText.disclaimer))
    }

    /// The names the windows read are the files the repository ships.
    @Test(arguments: [LegalText.licenseFile, LegalText.noticesFile])
    func theFilesTheWindowsReadExist(name: String) throws {
        #expect(try !Self.repositoryText(name).isEmpty)
    }

    @Test func linesInAParagraphAreJoined() {
        let text = "Permission is hereby granted,\n  free of charge,\nto any person.\n\nSecond paragraph."
        #expect(LegalText.reflowed(text) == [
            .paragraph("Permission is hereby granted, free of charge, to any person."),
            .paragraph("Second paragraph.")
        ])
    }

    @Test func anUnderlinedLineIsAHeadingAndOtherDividersAreDropped() {
        let text = "=================\nEXTERNAL LICENSES\n=================\n\nbsdiff\n\n--\n\nsais"
        #expect(LegalText.reflowed(text) == [
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
        #expect(LegalText.reflowed(text) == [
            .paragraph("Copyright (c) 2006 One.\u{2028}Copyright (c) 2009 Two. All rights reserved."),
            .paragraph(
                "are met:\u{2028}1. Redistributions of source code must retain the above copyright notice."
                    + "\u{2028}2. Redistributions in binary form\u{2028}(a) You must give"
            )
        ])
    }

    /// The shipped files, reflowed: every word kept in order and no divider left.
    @Test(arguments: [LegalText.licenseFile, LegalText.noticesFile])
    func reflowingAShippedFileKeepsEveryWord(name: String) throws {
        let text = try Self.repositoryText(name)
        let blocks = LegalText.reflowed(text)
        let original = Self.words(text)
        #expect(original.count > 100)
        #expect(Self.words(blocks) == original)
        for case let .paragraph(paragraph) in blocks {
            #expect(!paragraph.contains("\n"))
        }
    }

    /// Versions are left out on purpose: `scripts/check-notices.sh` already holds
    /// the notices to the resolved versions, and a bump should not need this test.
    @Test func everyNoticeIsAHeading() throws {
        let blocks = try LegalText.reflowed(Self.repositoryText(LegalText.noticesFile))
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
