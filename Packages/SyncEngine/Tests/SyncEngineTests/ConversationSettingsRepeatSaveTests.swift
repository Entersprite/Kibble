import ChatKit
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConversationSettingsRepeatSaveTests {
    @Test func settingsSavesRecoverAfterAFailureWithoutReopeningThePanel() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        await backend.failMutation(number: 2)
        for (index, access) in [ConversationAccess.discoverable, .open, .open, .restricted].enumerated() {
            browser.mutate(.settings(.init(access: access)))
            await browser.writeTask?.value
            await browser.detailsTask?.value
            #expect(browser.panelTarget == tests.space)
            #expect(!browser.isSubmitting)
            #expect(!browser.needsReconciliation, "A completed read must unblock the next explicit Save.")
            #expect(await backend.mutationCount == index + 1, "The failed write must not be resubmitted.")
            if index == 1 {
                #expect(browser.panelError != nil)
                #expect(browser.details?.access == .discoverable)
            } else {
                #expect(browser.details?.access == access)
                #expect(browser.panelError == nil)
            }
        }
    }

    @Test func anOldPeopleFailureCannotPoisonTheNextSettingsSave() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        await backend.hold(.participants)
        browser.mutate(.settings(.init(access: .discoverable)))
        await browser.writeTask?.value
        let oldRead = try #require(browser.detailsTask)
        for _ in 0 ..< 200 where await !backend.isHolding(.participants) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHolding(.participants))
        await backend.hold(.mutation)
        browser.mutate(.settings(.init(access: .open)))
        for _ in 0 ..< 200 where await !backend.isHolding(.mutation) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHolding(.mutation))
        await backend.failNextParticipants()
        await backend.release(.participants)
        await oldRead.value
        #expect(browser.isSubmitting)
        #expect(browser.panelError == nil)
        await backend.release(.mutation)
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(browser.details?.access == .open)
        #expect(!browser.needsReconciliation)
        #expect(browser.panelError == nil)
    }

    @Test func aFailedRecoveryReadKeepsWritesBlockedButReloadStillWorksInTheSamePanel() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        await backend.failMutation(number: 1)
        await backend.failNextDetails()
        browser.mutate(.settings(.init(access: .open)))
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(browser.needsReconciliation)
        browser.mutate(.settings(.init(access: .open)))
        #expect(await backend.mutationCount == 1)
        browser.openDetails(tests.space)
        await browser.detailsTask?.value
        #expect(!browser.needsReconciliation)
        browser.mutate(.settings(.init(access: .open)))
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(browser.details?.access == .open)
        #expect(await backend.mutationCount == 2)
    }

    @Test func aConfirmedMetadataSaveUsesItsReturnedDetailsWithoutAnotherDetailsRequest() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        for access in [ConversationAccess.discoverable, .open, .restricted] {
            browser.mutate(.settings(.init(access: access)))
            await browser.writeTask?.value
            await browser.detailsTask?.value
            #expect(!browser.needsReconciliation)
            #expect(browser.details?.access == access)
        }
        #expect(await backend.detailsReads == 1)
    }
}
