import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// The coordinator's guards against its own sequences: a click on a running
/// chip, a transfer outliving the sign-out that stopped it, and a URL inside
/// an error's text.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DownloadCoordinatorGuardTests {
    @Test func openWhileDownloadingDoesNothing() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        let running = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        fixture.coordinator.open(DownloadFixture.report)
        #expect(fixture.state == .downloading(AttachmentProgress(bytesReceived: 0, totalBytes: 3)))
        #expect(fixture.coordinator.task(for: DownloadFixture.report) == running)
        #expect(fixture.platform.opened.isEmpty)
        await fixture.script.release()
        await running.value
        #expect(fixture.state == .done)
        #expect(await fixture.script.destinations.count == 1)
    }

    @Test func aStoppedTransferEndingLateLeavesItsSuccessorAlone() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        await fixture.script.hold()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld()
        let first = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        fixture.coordinator.stopAll()
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.waitUntilHeld(2)
        let second = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        try #require(second != first)
        let starting = AttachmentDownloadState.downloading(AttachmentProgress(
            bytesReceived: 0,
            totalBytes: 3
        ))
        try #require(fixture.state == starting)

        // The stopped transfer reports progress, then ends, after its successor began.
        let stale = try #require(await fixture.script.progressCallbacks.first)
        stale(AttachmentProgress(bytesReceived: 2, totalBytes: 3))
        await fixture.script.releaseOldest()
        await first.value
        _ = await eventually(timeout: .milliseconds(100)) { fixture.state != starting }
        #expect(fixture.state == starting)
        #expect(fixture.coordinator.task(for: DownloadFixture.report) == second)

        await fixture.script.release()
        await second.value
        #expect(fixture.state == .done)
        #expect(fixture.names(in: fixture.folder) == ["report.pdf"])
    }

    @Test func aStopBeforeTheTransferBeginsNeitherCallsTheBackendNorRecreatesStaging() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        fixture.coordinator.start(DownloadFixture.report)
        let task = try #require(fixture.coordinator.task(for: DownloadFixture.report))
        fixture.coordinator.stopAll()
        await task.value
        #expect(await fixture.script.destinations.isEmpty)
        #expect(!fixture.exists(fixture.staging))
        #expect(fixture.state == nil)
    }

    @Test func aURLInsideAnErrorIsNeverShown() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.cleanUp() }
        let leaked = "failed at https://chat.usercontent.google.com/download?attachment_token=lowercasetoken"
        await fixture.script.fail(with: .unknown(leaked))
        fixture.coordinator.start(DownloadFixture.report)
        try await fixture.finish()
        #expect(fixture.state == .failed("The download could not be saved"))
        for error in [ChatError.transport(leaked), .decoding(leaked), .unknown(leaked)] {
            let text = DownloadCoordinator.message(for: error)
            #expect(text == "The download could not be saved")
            #expect(!text.contains("lowercasetoken"))
        }
        // Positive control: a payload with no URL in it is still shown as sent.
        #expect(DownloadCoordinator.message(for: ChatError.transport("The network connection was lost."))
            == "The network connection was lost.")
    }
}
