import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// Save As onto a file that already exists: the person confirmed the
/// replacement in the panel, so the old file goes - but only once the new one
/// exists, and never when the two are the same file. The new one is built in
/// the system's item-replacement directory, never in the target's folder: the
/// save panel extends the sandbox to the chosen file, not to its folder.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DownloadReplaceTests {
    private static let old = Data("OLD".utf8)
    private static let pdf = Data("PDF".utf8)

    private static func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// The file system's identity for the file at `url`, read fresh.
    private static func identity(of url: URL) throws -> NSObject? {
        let fresh = URL(filePath: url.path(percentEncoded: false))
        return try fresh.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
    }

    /// A directory beside the download folder holding `existing.pdf` = "OLD",
    /// and nothing else.
    private static func existingTarget(in fixture: DownloadFixture) throws -> URL {
        let directory = fixture.root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "existing.pdf")
        try old.write(to: target)
        try #require(fixture.names(in: directory) == ["existing.pdf"])
        return target
    }

    @Test func saveAsOntoThePlacedFileItselfKeepsIt() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let placed = fixture.folder.appending(path: "report.pdf")
        let before = try #require(try Self.identity(of: placed))
        fixture.platform.saveDestination = placed
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: placed) == Self.pdf)
        // Nothing was replaced: still the same file, not a copy of it.
        #expect(try Self.identity(of: placed) == before)
        #expect(fixture.state == .done)
        #expect(fixture.names(in: fixture.folder) == ["report.pdf"])
        #expect(fixture.platform.failures.isEmpty)
    }

    @Test func saveAsOverAnotherFileReplacesItsBytes() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let target = try Self.existingTarget(in: fixture)
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: target) == Self.pdf)
        #expect(try Data(contentsOf: fixture.folder.appending(path: "report.pdf")) == Self.pdf)
        #expect(fixture.names(in: target.deletingLastPathComponent()) == ["existing.pdf"])
        #expect(fixture.state == .done)
        #expect(fixture.platform.failures.isEmpty)
    }

    @Test func aCopyThatCannotReadItsSourceLeavesTheTargetAlone() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let placed = fixture.folder.appending(path: "report.pdf")
        let target = try Self.existingTarget(in: fixture)
        try Self.setPermissions(0o000, of: placed)
        defer { try? Self.setPermissions(0o644, of: placed) }
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: target) == Self.old)
        #expect(fixture.names(in: target.deletingLastPathComponent()) == ["existing.pdf"])
        #expect(fixture.exists(placed))
        #expect(fixture.state == .done)
        #expect(fixture.platform.failures.count == 1)
    }

    @Test func aFolderThatRefusesTheCopyLeavesTheTargetAlone() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let target = try Self.existingTarget(in: fixture)
        let directory = target.deletingLastPathComponent()
        try Self.setPermissions(0o555, of: directory)
        defer { try? Self.setPermissions(0o755, of: directory) }
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: target) == Self.old)
        #expect(fixture.names(in: directory) == ["existing.pdf"])
        #expect(fixture.state == .done)
        #expect(fixture.platform.failures.count == 1)
    }

    /// The replacement is made before the replace fails, so this is the case
    /// that shows where it was made: nothing is ever added to the target's
    /// folder, even for a moment.
    /// The chip still says the file is downloaded, because it is, and the
    /// failure is shown once instead.
    @Test func aTargetThatCannotBeReplacedIsLeftAloneAndItsFolderNeverTouched() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let target = try Self.existingTarget(in: fixture)
        let directory = target.deletingLastPathComponent()
        let path = target.path(percentEncoded: false)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        let watch = try FolderWriteWatch(directory)
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(!watch.changed())
        #expect(try Data(contentsOf: target) == Self.old)
        #expect(fixture.names(in: directory) == ["existing.pdf"])
        #expect(fixture.state == .done)
        #expect(fixture.platform.failures == ["Kibble couldn't save “existing.pdf”"])
        // Positive control: the watch does see a file added to the folder.
        try Data().write(to: directory.appending(path: "control"))
        #expect(watch.changed())
    }

    @Test func aDownloadStraightOverAnotherFileReplacesItsBytes() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        let target = try Self.existingTarget(in: fixture)
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        try await fixture.finish()
        #expect(fixture.state == .done)
        #expect(try Data(contentsOf: target) == Self.pdf)
        #expect(fixture.names(in: target.deletingLastPathComponent()) == ["existing.pdf"])
        #expect(fixture.names(in: fixture.staging).isEmpty)
    }

    /// A name nothing holds yet: the file arrives under it, and it is the
    /// only thing the folder gains.
    @Test func saveAsToANewNameAddsOnlyThatFile() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let directory = fixture.root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(fixture.names(in: directory).isEmpty)
        let target = directory.appending(path: "copy.pdf")
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: target) == Self.pdf)
        #expect(fixture.names(in: directory) == ["copy.pdf"])
        #expect(fixture.state == .done)
    }
}
