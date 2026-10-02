import AppCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DownloadNamingTests {
    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "-..-etc-passwd"),
        ("a/b:c.txt", "a-b-c.txt"),
        ("...", "Attachment"),
        ("", "Attachment"),
        ("  .hidden.txt", "hidden.txt"),
        ("bell\u{07}.txt", "bell.txt")
    ])
    func leaf(_ name: String, _ expected: String) {
        let leaf = DownloadNaming.leaf(name)
        #expect(leaf == expected)
        #expect(!leaf.contains("/"))
        #expect(!leaf.hasPrefix("."))
    }

    @Test(
        "a long name is cut to 240 UTF-8 bytes, room for a \" 9999\" suffix, keeping its extension",
        arguments: [String(repeating: "x", count: 296) + ".pdf", String(repeating: "é", count: 296) + ".pdf"]
    )
    func longNames(_ name: String) {
        let leaf = DownloadNaming.leaf(name)
        #expect(leaf.utf8.count <= 240)
        #expect(leaf.utf8.count > 200)
        #expect(leaf.hasSuffix(".pdf"))
    }

    @Test("an extension longer than the cap is cut with the rest rather than kept")
    func longExtension() {
        let leaf = DownloadNaming.leaf("a." + String(repeating: "x", count: 300))
        #expect(leaf.utf8.count <= 240)
        #expect(leaf.hasPrefix("a"))
    }

    @Test("placing into a folder that already holds the name gives name 2, then name 3")
    func collisions() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.folder(in: root)
        for index in 0 ..< 3 {
            let staged = try Self.staged(in: root, index: index)
            _ = try DownloadNaming.place(staged, as: "report.pdf", in: folder)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .sorted()
        #expect(names == ["report 2.pdf", "report 3.pdf", "report.pdf"])
    }

    @Test("a name without an extension gets the number at its end")
    func noExtension() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.folder(in: root)
        for index in 0 ..< 2 {
            let staged = try Self.staged(in: root, index: index)
            _ = try DownloadNaming.place(staged, as: "README", in: folder)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .sorted()
        #expect(names == ["README", "README 2"])
    }

    @Test("the placed URL is the file that was written, and the staged file is gone")
    func placeReturnsTheFile() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.folder(in: root)
        let staged = try Self.staged(in: root, index: 0)
        let placed = try DownloadNaming.place(staged, as: "screen shot.png", in: folder)
        #expect(placed.lastPathComponent == "screen shot.png")
        #expect(try Data(contentsOf: placed) == Data("file 0".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "download-naming-tests-\(UUID().uuidString)")
    }

    private static func folder(in root: URL) throws -> URL {
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A file written somewhere other than the folder, as a transfer stages one.
    private static func staged(in root: URL, index: Int) throws -> URL {
        let directory = root.appending(path: "staging-\(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "staged")
        try Data("file \(index)".utf8).write(to: file)
        return file
    }
}
