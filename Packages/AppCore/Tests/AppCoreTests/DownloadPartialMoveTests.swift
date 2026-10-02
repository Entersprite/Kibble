import Foundation
import Testing
@testable import AppCore

/// A move that stops part-way. On one volume a move is a rename and cannot,
/// so these stand a scripted move in for the copy a move across volumes
/// really is: it leaves `PART` at the name it was given and then fails. What
/// is tested is the clean-up rule - a name that was free is cleared, a name
/// someone holds is not - and not that a real cross-volume move leaves a
/// part-copy behind, which is `[Verify]`. The last test uses the seam only to
/// see where Save As builds its replacement.
@Suite(.timeLimit(.minutes(1)))
struct DownloadPartialMoveTests {
    private static let mine = Data("MINE".utf8)

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?
            .sorted() ?? []
    }

    /// Refuses a name that is taken - giving a reason other than "exists",
    /// so only looking first keeps that file - and otherwise writes part of
    /// the file there and runs out of space.
    private static let stopsPartWay: DownloadNaming.Move = { _, destination in
        if exists(destination) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Data("PART".utf8).write(to: destination)
        throw CocoaError(.fileWriteOutOfSpace)
    }

    private struct Folders {
        let root: URL
        let folder: URL
        let staged: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(
                    path: "download-partial-move-tests-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            staged = root.appending(path: "staged")
            try Data("PDF".utf8).write(to: staged)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func aPlacementThatStopsPartWayLeavesNoPartCopyAndKeepsTheTakenName() throws {
        let folders = try Folders()
        defer { folders.cleanUp() }
        let taken = folders.folder.appending(path: "report.pdf")
        try Self.mine.write(to: taken)
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
            _ = try DownloadNaming.place(
                folders.staged,
                as: "report.pdf",
                in: folders.folder,
                moving: Self.stopsPartWay
            )
        }
        #expect(Self.names(in: folders.folder) == ["report.pdf"])
        #expect(try Data(contentsOf: taken) == Self.mine)
        #expect(Self.exists(folders.staged))
    }

    /// The name was free when the placement looked and taken by the time it
    /// moved: that file stays, and the download takes the next name.
    @Test func aPlacementWhoseNameIsTakenMeanwhileKeepsThatFile() throws {
        let folders = try Folders()
        defer { folders.cleanUp() }
        let taken = folders.folder.appending(path: "report.pdf")
        let takenMeanwhile: DownloadNaming.Move = { source, destination in
            if destination.lastPathComponent == "report.pdf" {
                try Self.mine.write(to: destination)
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let placed = try DownloadNaming.place(
            folders.staged,
            as: "report.pdf",
            in: folders.folder,
            moving: takenMeanwhile
        )
        #expect(placed.lastPathComponent == "report 2.pdf")
        #expect(try Data(contentsOf: taken) == Self.mine)
        #expect(try Data(contentsOf: placed) == Data("PDF".utf8))
    }

    @Test func aSaveAsToAFreeNameThatStopsPartWayLeavesNothingThere() throws {
        let folders = try Folders()
        defer { folders.cleanUp() }
        let target = folders.folder.appending(path: "copy.pdf")
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
            try DownloadNaming.deliver(folders.staged, to: target, copying: true, moving: Self.stopsPartWay)
        }
        #expect(Self.names(in: folders.folder).isEmpty)
        #expect(Self.exists(folders.staged))
    }

    /// The name was free when Save As looked and taken by the time it moved:
    /// what took it is someone else's file.
    @Test func aSaveAsWhoseNameIsTakenMeanwhileLeavesTheNewFileAlone() throws {
        let folders = try Folders()
        defer { folders.cleanUp() }
        let target = folders.folder.appending(path: "copy.pdf")
        let takenMeanwhile: DownloadNaming.Move = { _, destination in
            try Self.mine.write(to: destination)
            throw CocoaError(.fileWriteFileExists)
        }
        #expect(throws: CocoaError(.fileWriteFileExists)) {
            try DownloadNaming.deliver(folders.staged, to: target, copying: true, moving: takenMeanwhile)
        }
        #expect(try Data(contentsOf: target) == Self.mine)
    }

    /// Where a download straight to a Save As target is built: not beside the
    /// target, and gone afterwards whether the replace worked or not.
    @Test(arguments: [false, true])
    func theReplacementIsBuiltElsewhereAndRemoved(replaceFails: Bool) throws {
        let folders = try Folders()
        defer { folders.cleanUp() }
        let target = folders.folder.appending(path: "existing.pdf")
        try Self.mine.write(to: target)
        let path = target.path(percentEncoded: false)
        if replaceFails {
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        let seen = MoveLog()
        let recording: DownloadNaming.Move = { source, destination in
            seen.append(destination)
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            try DownloadNaming.deliver(folders.staged, to: target, copying: false, moving: recording)
            #expect(!replaceFails)
        } catch {
            #expect(replaceFails)
        }
        let replacement = try #require(seen.destinations.first)
        let scratch = replacement.deletingLastPathComponent()
        let folder = folders.folder.standardizedFileURL.path(percentEncoded: false)
        #expect(!scratch.standardizedFileURL.path(percentEncoded: false).hasPrefix(folder))
        #expect(!Self.exists(scratch))
        #expect(Self.names(in: folders.folder) == ["existing.pdf"])
        #expect(try Data(contentsOf: target) == (replaceFails ? Self.mine : Data("PDF".utf8)))
    }
}

/// The destinations a recording move was given, from whatever thread.
private final class MoveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL] = []

    func append(_ url: URL) {
        lock.withLock { entries.append(url) }
    }

    var destinations: [URL] {
        lock.withLock { entries }
    }
}
