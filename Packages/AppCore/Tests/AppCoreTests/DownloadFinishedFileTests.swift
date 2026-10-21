import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `finishedFile`: where a drag, a share or Quick Look finds a finished
/// download. Unlike Open, it never starts a transfer.
@MainActor
struct DownloadFinishedFileTests {
    @Test func aFinishedDownloadIsWhereItWasPlaced() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.coordinator.finishedFile(DownloadFixture.report) == nil)
        try await fixture.downloadToDone()
        let file = try #require(fixture.coordinator.finishedFile(DownloadFixture.report))
        #expect(file.lastPathComponent == "report.pdf")
        #expect(fixture.exists(file))
    }

    @Test func aFileThatHasGoneIsNotDownloadedAgain() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "report.pdf"))
        #expect(fixture.coordinator.finishedFile(DownloadFixture.report) == nil)
        #expect(fixture.coordinator.task(for: DownloadFixture.report) == nil)
        #expect(fixture.state == .done)
        #expect(await fixture.script.destinations.count == 1)
    }

    @Test func nothingIsFinishedWhileATransferRuns() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        #expect(fixture.coordinator.finishedFile(DownloadFixture.report) == nil)
        await fixture.script.release()
        try await fixture.finish()
        #expect(fixture.coordinator.finishedFile(DownloadFixture.report) != nil)
    }
}
