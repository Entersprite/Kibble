// Builds DesignSystem's emoji.json from Unicode's emoji-test.txt and CLDR's English
// annotations (reactions spec §4.3). Run through scripts/generate-emoji.sh, which pins
// and downloads the inputs; this file only reads them.
//
//   xcrun swift scripts/generate-emoji.swift <emoji-test.txt> <annotations.json> \
//       <annotationsDerived.json> <unicode-version> <cldr-version> <out.json>
//
// Keeps fully-qualified emoji only, in emoji-test.txt's order, grouped by its
// groups (the "Component" group is dropped). An emoji whose five single-tone
// variants all exist takes a skin tone, and carries them. Every kept emoji and
// tone variant must draw as one glyph in Apple Color Emoji on the Mac that runs
// this, so the grid never shows an empty box - which means the list follows that
// Mac's macOS version. [Verify] after an OS update: regenerate and diff.

import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 7 else {
    FileHandle.standardError.write(Data("usage: generate-emoji.swift test annotations derived unicode cldr out\n".utf8))
    exit(2)
}
let (testPath, annotationsPath, derivedPath) = (arguments[1], arguments[2], arguments[3])
let (unicodeVersion, cldrVersion, outPath) = (arguments[4], arguments[5], arguments[6])

let modifiers: ClosedRange<UInt32> = 0x1F3FB ... 0x1F3FF

/// Without U+FE0F, the form CLDR's keys and the tone variants are compared in.
func normalised(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
}

let emojiFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)

/// One run from the emoji font, no .notdef, and exactly one glyph with an
/// advance: the system draws it as one emoji. Not "exactly one glyph": the
/// kiss and couple sequences shape to a zero-advance glyph plus the visible
/// one, and counting glyphs dropped all six (slice 2 review, Important 2).
func drawsAsOneGlyph(_ emoji: String) -> Bool {
    let attributed = NSAttributedString(
        string: emoji, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): emojiFont]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    guard runs.count == 1 else { return false }
    let count = CTRunGetGlyphCount(runs[0])
    guard count >= 1 else { return false }
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var advances = [CGSize](repeating: .zero, count: count)
    CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 0), &glyphs)
    CTRunGetAdvances(runs[0], CFRange(location: 0, length: 0), &advances)
    return !glyphs.contains(0) && advances.filter { $0.width > 0 }.count == 1
}

// MARK: - emoji-test.txt

struct Base {
    let emoji: String
    let group: String
    let fallbackName: String
}

var bases: [Base] = []
var tones: [String: [Int: String]] = [:]
var group = ""

let testFile = try String(contentsOfFile: testPath, encoding: .utf8)
for line in testFile.split(separator: "\n", omittingEmptySubsequences: true) {
    if line.hasPrefix("# group: ") {
        group = String(line.dropFirst("# group: ".count))
        continue
    }
    guard !line.hasPrefix("#"), group != "Component" else { continue }
    let halves = line.split(separator: "#", maxSplits: 1)
    guard halves.count == 2 else { continue }
    let fields = halves[0].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count == 2, fields[1] == "fully-qualified" else { continue }
    let scalars = fields[0].split(separator: " ").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
    let emoji = String(String.UnicodeScalarView(scalars))
    let toneIndices = scalars.filter { modifiers.contains($0.value) }.map { Int($0.value - modifiers.lowerBound) }
    if toneIndices.isEmpty {
        // "# 😀 E1.0 grinning face": the name is everything after the version.
        let comment = halves[1].split(separator: " ", maxSplits: 2)
        bases.append(Base(emoji: emoji, group: group, fallbackName: comment.count == 3 ? String(comment[2]) : ""))
    } else if Set(toneIndices).count == 1 {
        let base = String(String.UnicodeScalarView(scalars.filter { !modifiers.contains($0.value) }))
        tones[normalised(base), default: [:]][toneIndices[0]] = emoji
    }
}

// MARK: - CLDR

func annotations(at path: String, root: String) throws -> [String: [String: Any]] {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    let top = (json as? [String: Any])?[root] as? [String: Any]
    let table = top?["annotations"] as? [String: [String: Any]] ?? [:]
    var byKey: [String: [String: Any]] = [:]
    for (key, value) in table {
        byKey[normalised(key)] = value
    }
    return byKey
}

let cldr = try annotations(at: annotationsPath, root: "annotations")
    .merging(annotations(at: derivedPath, root: "annotationsDerived")) { plain, _ in plain }

// MARK: - Output

var categories: [(name: String, emoji: [[String: Any]])] = []
var dropped = 0
for base in bases {
    guard drawsAsOneGlyph(base.emoji) else {
        dropped += 1
        continue
    }
    let annotation = cldr[normalised(base.emoji)]
    let name = (annotation?["tts"] as? [String])?.first ?? base.fallbackName
    var entry: [String: Any] = ["e": base.emoji, "n": name, "k": annotation?["default"] as? [String] ?? []]
    if let variants = tones[normalised(base.emoji)], variants.count == 5,
       let ordered = Optional((0 ..< 5).compactMap { variants[$0] }), ordered.allSatisfy(drawsAsOneGlyph) {
        entry["t"] = ordered
    }
    if categories.last?.name != base.group {
        categories.append((base.group, []))
    }
    categories[categories.count - 1].emoji.append(entry)
}

let document: [String: Any] = [
    "unicodeEmojiVersion": unicodeVersion,
    "cldrVersion": cldrVersion,
    "categories": categories.map { ["name": $0.name, "emoji": $0.emoji] }
]
let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: outPath))
let kept = categories.reduce(0) { $0 + $1.emoji.count }
let toned = categories.reduce(0) { $0 + $1.emoji.count { $0["t"] != nil } }
print("emoji.json: \(kept) emoji in \(categories.count) categories, \(toned) take a skin tone; \(dropped) dropped (no single glyph); \(data.count) bytes")
