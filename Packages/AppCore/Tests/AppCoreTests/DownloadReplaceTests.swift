import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// Save As onto a file that already exists: the person confirmed the
/// replacement in the panel, so the old file goes - but only once the new one
/// exists, and never when the two are the same file.
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

    private static func siblings(in fixture: DownloadFixture, _ directory: URL) -> [String] {
        fixture.names(in: directory).filter { $0.hasPrefix(".kibble-") }
    }

    /// A directory beside the download folder holding `existing.pdf` = "OLD".
    private static func existingTarget(in fixture: DownloadFixture) throws -> URL {
        let directory = fixture.root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "existing.pdf")
        try old.write(to: target)
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
        #expect(Self.siblings(in: fixture, fixture.folder).isEmpty)
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
        #expect(Self.siblings(in: fixture, target.deletingLastPathComponent()).isEmpty)
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
        #expect(Self.siblings(in: fixture, target.deletingLastPathComponent()).isEmpty)
        #expect(fixture.exists(placed))
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
        #expect(Self.siblings(in: fixture, directory).isEmpty)
    }

    /// The replacement exists beside the target before the replace fails, so
    /// this is the case where the sibling must be cleaned up.
    @Test func aTargetThatCannotBeReplacedIsLeftAloneWithNoSibling() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let target = try Self.existingTarget(in: fixture)
        let path = target.path(percentEncoded: false)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(try Data(contentsOf: target) == Self.old)
        #expect(Self.siblings(in: fixture, target.deletingLastPathComponent()).isEmpty)
        guard case .failed = fixture.state else {
            Issue.record("expected failed, got \(String(describing: fixture.state))")
            return
        }
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
        #expect(Self.siblings(in: fixture, target.deletingLastPathComponent()).isEmpty)
        #expect(fixture.names(in: fixture.staging).isEmpty)
    }
}
