import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DownloadCoordinatorTests {
    @Test func aFinishedDownloadIsPlacedUnderItsLeafNameAndStagingIsEmpty() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        #expect(fixture.names(in: fixture.folder) == ["report.pdf"])
        #expect(try Data(contentsOf: fixture.folder.appending(path: "report.pdf")) == Data("PDF".utf8))
        #expect(fixture.names(in: fixture.staging).isEmpty)
        #expect(fixture.coordinator.task(for: DownloadFixture.report) == nil)
    }

    @Test func aSecondStartOrSaveAsWhileRunningIsIgnored() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        fixture.platform.saveDestination = fixture.root.appending(path: "elsewhere.pdf")
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        fixture.coordinator.start(DownloadFixture.report)
        fixture.coordinator.saveAs(DownloadFixture.report)
        // Give a second transfer every chance to reach the backend.
        _ = await eventually(timeout: .milliseconds(100)) { await fixture.script.heldCount > 1 }
        #expect(await fixture.script.destinations.count == 1)
        await fixture.script.release()
        try await fixture.finish()
        #expect(fixture.state == .done)
        #expect(await fixture.script.destinations.count == 1)
        #expect(fixture.names(in: fixture.folder) == ["report.pdf"])
    }

    @Test func aCancelledDownloadLeavesNoStateAndNoFiles() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        try #require(fixture.state == .downloading(AttachmentProgress(bytesReceived: 0, totalBytes: 3)))
        let task = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        fixture.coordinator.cancel(DownloadFixture.report)
        await fixture.script.release()
        await task.value
        #expect(fixture.state == nil)
        #expect(fixture.names(in: fixture.folder).isEmpty)
        #expect(fixture.names(in: fixture.staging).isEmpty)
    }

    @Test func anExpiredSignInSaysSignInAgain() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.fail(with: .signInRequired("x"))
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.finish()
        #expect(fixture.state == .failed("Sign in again to download files"))
    }

    @Test func aRefusalNamesItsStatusAndNoURL() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.fail(with: .server(
            status: 403,
            message: "https://chat.example.invalid/x?token=t"
        ))
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.finish()
        guard case let .failed(text) = fixture.state else {
            Issue.record("expected failed, got \(String(describing: fixture.state))")
            return
        }
        #expect(text.contains("403"))
        #expect(!text.contains("://"))
        #expect(!text.contains("token"))
        #expect(fixture.names(in: fixture.folder).isEmpty)
    }

    @Test func anUnusableFolderIsNamed() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        fixture.platform.accessFailure = DownloadFolderUnavailable(folderName: "Projects")
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.finish()
        guard case let .failed(text) = fixture.state else {
            Issue.record("expected failed, got \(String(describing: fixture.state))")
            return
        }
        #expect(text.contains("Projects"))
        #expect(fixture.names(in: fixture.staging).isEmpty)
    }

    @Test func progressMovesTheChipWhileRunningAndNeverAfterDone() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        let progress = try #require(await fixture.script.progress)
        let halfway = AttachmentProgress(bytesReceived: 1, totalBytes: 3)
        // Positive control: progress during the transfer does land.
        progress(halfway)
        _ = await eventually { fixture.state == .downloading(halfway) }
        try #require(fixture.state == .downloading(halfway))

        await fixture.script.release()
        try await fixture.finish()
        try #require(fixture.state == .done)
        progress(AttachmentProgress(bytesReceived: 3, totalBytes: 3))
        _ = await eventually(timeout: .milliseconds(200)) { fixture.state != .done }
        #expect(fixture.state == .done)
    }

    @Test func openingADeletedFileDownloadsItAgain() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "report.pdf"))
        fixture.coordinator.open(DownloadFixture.report)
        #expect(fixture.platform.opened.isEmpty)
        try await fixture.finish()
        #expect(fixture.state == .done)
        #expect(await fixture.script.destinations.count == 2)
        #expect(fixture.names(in: fixture.folder) == ["report.pdf"])
    }

    @Test func openAndRevealHandThePlacedFileToThePlatform() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        fixture.coordinator.open(DownloadFixture.report)
        fixture.coordinator.reveal(DownloadFixture.report)
        let placed = fixture.folder.appending(path: "report.pdf").path(percentEncoded: false)
        #expect(fixture.platform.opened.map { $0.path(percentEncoded: false) } == [placed])
        #expect(fixture.platform.revealed.map { $0.path(percentEncoded: false) } == [placed])
        #expect(await fixture.script.destinations.count == 1)
    }

    @Test func saveAsCopiesAFinishedFileAndKeepsTheOriginal() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        try await fixture.downloadToDone()
        let target = fixture.root.appending(path: "my copy.pdf")
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        #expect(fixture.platform.suggestedNames == ["report.pdf"])
        #expect(try Data(contentsOf: target) == Data("PDF".utf8))
        #expect(fixture.exists(fixture.folder.appending(path: "report.pdf")))
        #expect(fixture.state == .done)
        #expect(await fixture.script.destinations.count == 1)
    }

    @Test func saveAsBeforeDownloadingDownloadsStraightToTheDestination() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        let target = fixture.root.appending(path: "my copy.pdf")
        fixture.platform.saveDestination = target
        fixture.coordinator.saveAs(DownloadFixture.report)
        try await fixture.finish()
        #expect(fixture.state == .done)
        #expect(try Data(contentsOf: target) == Data("PDF".utf8))
        #expect(fixture.names(in: fixture.folder).isEmpty)
        #expect(fixture.names(in: fixture.staging).isEmpty)
    }

    @Test func stopAllCancelsTheTransferAndRemovesStaging() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        try #require(fixture.exists(fixture.staging))
        let task = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        fixture.coordinator.stopAll()
        #expect(!fixture.exists(fixture.staging))
        await fixture.script.release()
        await task.value
        #expect(fixture.state == nil)
        #expect(!fixture.exists(fixture.staging))
        #expect(fixture.names(in: fixture.folder).isEmpty)
    }
}
