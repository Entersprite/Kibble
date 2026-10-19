import AppCore
import ChatAPI
import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import MacHost

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountFixtureHostTests {
    @Test func bothNativeAccountComposersUploadThroughTheServiceWithoutMixingMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 42, count: 70000).write(to: file)
        let host = SystemAccountFixtureHost(directory: directory)
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace, count: 2)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        let personal = try #require(workspace.environment(for: first.id))
        let studio = try #require(workspace.environment(for: second.id))
        personal.actions.select(Acme.priceEngine)
        studio.actions.select(Acme.priceEngine)
        try await wait { !personal.sceneState.messages.isEmpty && !studio.sceneState.messages.isEmpty }
        let personalFiles = try #require(personal.actions.composerAttachments)
        let studioFiles = try #require(studio.actions.composerAttachments)
        personalFiles.stage([file])
        #expect(personal.sceneState.stagedAttachments.count == 1)
        #expect(studio.sceneState.stagedAttachments.isEmpty)
        personal.actions.send(ComposedMessage(text: "Personal file caption"))
        try await wait {
            personal.sceneState.messages
                .contains { $0.text == "Personal file caption" && !$0.attachments.isEmpty }
                && personal.sceneState.stagedAttachments.isEmpty
        }
        #expect(!studio.sceneState.messages.contains { $0.text == "Personal file caption" })
        studioFiles.stage([file])
        studio.actions.send(ComposedMessage(text: "Studio file caption"))
        try await wait {
            studio.sceneState.messages
                .contains { $0.text == "Studio file caption" && !$0.attachments.isEmpty }
                && studio.sceneState.stagedAttachments.isEmpty
        }
        #expect(!personal.sceneState.messages.contains { $0.text == "Studio file caption" })
        let personalAttachment = try #require(personal.sceneState.messages.first {
            $0.text == "Personal file caption"
        }?.attachments.first)
        let studioAttachment = try #require(studio.sceneState.messages.first {
            $0.text == "Studio file caption"
        }?.attachments.first)
        let personalLoader = try #require(personal.actions.loadAttachment)
        let studioLoader = try #require(studio.actions.loadAttachment)
        #expect(try await personalLoader(personalAttachment, .preview).starts(with: Data([137, 80, 78, 71])))
        #expect(try await studioLoader(studioAttachment, .preview).starts(with: Data([137, 80, 78, 71])))
        #expect(personal.actions.attachmentFiles != nil)
        #expect(studio.actions.attachmentFiles != nil)
        await host.stop()
    }

    @Test func canonicalNotificationChoicesRemainIsolatedAcrossDisableAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = SystemAccountFixtureHost(directory: directory)
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace, count: 2)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        let firstEnvironment = try #require(workspace.environment(for: first.id))
        let secondEnvironment = try #require(workspace.environment(for: second.id))
        try await wait { firstEnvironment.isPolicyReady && secondEnvironment.isPolicyReady }
        firstEnvironment.settings.update(NotificationRule(delivery: .off, readReceipts: false), for: .global)
        #expect(!firstEnvironment.isPolicyReady)
        try await wait { firstEnvironment.isPolicyReady }
        #expect(secondEnvironment.settings.settings.resolvedGlobal.readReceipts)
        #expect(secondEnvironment.settings.settings.resolvedGlobal.delivery == .bannerAndSound)
        try await wait {
            guard let revision = workspace.accounts.first(where: { $0.id == first.id })?.policyRevision
            else { return false }
            return revision != "0"
        }
        let revision = try #require(workspace.accounts.first { $0.id == first.id }?.policyRevision)
        #expect(revision != "0")
        await host.setEnabled(false, account: first.id.rawValue)
        try await wait { workspace.environment(for: first.id) == nil }
        await host.setEnabled(true, account: first.id.rawValue)
        try await ready(workspace, count: 2)
        let resumed = try #require(workspace.environment(for: first.id))
        try await wait { resumed.isPolicyReady }
        #expect(!resumed.settings.settings.resolvedGlobal.readReceipts)
        #expect(resumed.settings.settings.resolvedGlobal.delivery == .off)
        await host.stop()
        await host.start()
        let restarted = try #require(host.workspace)
        try await ready(restarted, count: 2)
        let restored = try #require(restarted.environment(for: first.id))
        try await wait { restored.isPolicyReady }
        #expect(!restored.settings.settings.resolvedGlobal.readReceipts)
        #expect(restored.settings.settings.resolvedGlobal.delivery == .off)
        await host.stop()
    }

    @Test func bothNativeReplicasReceiveLiveMessagesAcrossSelectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = SystemAccountFixtureHost(directory: directory)
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace, count: 2)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        let firstEnvironment = try #require(workspace.environment(for: first.id))
        let secondEnvironment = try #require(workspace.environment(for: second.id))
        firstEnvironment.actions.select(Acme.priceEngine)
        secondEnvironment.actions.select(Acme.priceEngine)
        try await wait {
            !firstEnvironment.sceneState.messages.isEmpty && !secondEnvironment.sceneState.messages.isEmpty
        }
        for index in 0 ..< 2 {
            let firstMarker = "First account arrival \(index)"
            let secondMarker = "Second account arrival \(index)"
            host.selectAccount(second.id.rawValue)
            await host.simulateMessage(first.id.rawValue, text: firstMarker)
            try await wait { firstEnvironment.sceneState.messages.contains { $0.text == firstMarker } }
            #expect(!secondEnvironment.sceneState.messages.contains { $0.text == firstMarker })
            host.selectAccount(first.id.rawValue)
            await host.simulateMessage(second.id.rawValue, text: secondMarker)
            try await wait { secondEnvironment.sceneState.messages.contains { $0.text == secondMarker } }
            #expect(!firstEnvironment.sceneState.messages.contains { $0.text == secondMarker })
        }
        try await wait {
            firstEnvironment.sceneState.lastError == nil && secondEnvironment.sceneState.lastError == nil
        }
        await host.stop()
        await host.start()
        let restoredWorkspace = try #require(host.workspace)
        try await ready(restoredWorkspace, count: 2)
        let restoredFirst = try #require(restoredWorkspace.environment(for: first.id))
        let restoredSecond = try #require(restoredWorkspace.environment(for: second.id))
        restoredFirst.actions.select(Acme.priceEngine)
        restoredSecond.actions.select(Acme.priceEngine)
        await host.simulateMessage(first.id.rawValue, text: "First arrival after relaunch")
        await host.simulateMessage(second.id.rawValue, text: "Second arrival after relaunch")
        try await wait {
            restoredFirst.sceneState.messages.contains { $0.text == "First arrival after relaunch" } &&
                restoredSecond.sceneState.messages.contains { $0.text == "Second arrival after relaunch" }
        }
        try await wait {
            restoredFirst.sceneState.lastError == nil && restoredSecond.sceneState.lastError == nil
        }
        await host.stop()
    }

    @Test func nativeFixtureRunsTwoAccountsAndReleasesDisabledProviderMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = SystemAccountFixtureHost(directory: directory)
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace, count: 2)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        #expect(await host.activeRuntimeCount == 2)
        #expect(await host.retainedProviderCount == 2)
        host.selectAccount(second.id.rawValue)
        let selected = try #require(workspace.selectedEnvironment)
        await host.setEnabled(false, account: first.id.rawValue)
        try await wait {
            let runtimes = await host.activeRuntimeCount
            let retained = await host.retainedProviderCount
            return runtimes == 1 && retained == 1 && workspace.environment(for: first.id) == nil
        }
        #expect(workspace.selectedEnvironment === selected)
        await host.setEnabled(true, account: first.id.rawValue)
        try await ready(workspace, count: 2)
        await host.stop()
        #expect(await host.retainedProviderCount == 0)
        #expect(await host.activeRuntimeCount == 0)
    }

    @Test func removalAndSelectionSurviveRelaunchWithoutReseeding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = SystemAccountFixtureHost(directory: directory)
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace, count: 2)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        host.selectAccount(second.id.rawValue)
        await host.removeAccount(first.id.rawValue)
        try await wait { workspace.accounts.count == 1 }
        await host.stop()
        let restarted = SystemAccountFixtureHost(directory: directory)
        await restarted.start()
        let restored = try #require(restarted.workspace)
        try await ready(restored, count: 1)
        #expect(restored.accounts.map(\.id) == [second.id])
        #expect(restored.selectedID == second.id)
        await restarted.stop()
    }

    @Test func aSecondNativeHostCannotOpenTheSameServiceDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = SystemAccountFixtureHost(directory: directory)
        await first.start()
        let workspace = try #require(first.workspace)
        try await ready(workspace, count: 2)
        let second = SystemAccountFixtureHost(directory: directory)
        await second.start()
        #expect(second.workspace == nil)
        #expect(second.error != nil)
        #expect(await first.activeRuntimeCount == 2)
        await first.stop()
        await second.start()
        #expect(second.workspace != nil)
        await second.stop()
    }

    private func ready(_ workspace: AccountWorkspace, count: Int) async throws {
        try await wait {
            workspace.accounts.count == count && workspace.accounts.allSatisfy {
                workspace.environment(for: $0.id) != nil
            }
        }
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ServiceFailure.deadlineExceeded
    }
}
