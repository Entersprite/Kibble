import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import Testing

struct DefaultPolicyTests {
    @Test func sharedChangesPreserveAccountOverridesAndRejectStaleWrites() throws {
        let store = try SQLiteAccountRegistry(path: ":memory:")
        let account = LinkHarness.existing()
        var settings = NotificationSettings()
        settings.setRule(.init(showsPreview: false), for: .global, at: .distantPast, by: "device")
        settings.setRule(
            .init(sound: .system),
            for: .conversation(.init("chat")),
            at: .distantPast,
            by: "device"
        )
        let saved = try store.setPolicy(settings, for: account, expectedRevision: "0")
        _ = try store.setDefaultPolicy(
            .init(showsPreview: true, readReceipts: false),
            for: account.principalID,
            expectedRevision: "0"
        )
        let inherited = try store.policy(for: account)
        #expect(inherited.revision != saved.revision)
        #expect(inherited.settings.records == settings.records)
        #expect(!inherited.settings.resolvedGlobal.showsPreview)
        #expect(!inherited.settings.resolvedGlobal.readReceipts)
        #expect(throws: ServiceFailure.revisionConflict) {
            try store.setPolicy(settings, for: account, expectedRevision: saved.revision)
        }
        var attempted = inherited.settings
        attempted.sharedDefaults = .init(readReceipts: true)
        _ = try store.setPolicy(attempted, for: account, expectedRevision: inherited.revision)
        #expect(try store.policy(for: account).settings.resolvedGlobal.readReceipts == false)
        _ = try store.setDefaultPolicy(.init(), for: account.principalID, expectedRevision: "1")
        let reset = try store.policy(for: account)
        #expect(reset.settings.records == settings.records)
        #expect(reset.settings.resolvedGlobal.readReceipts)
        #expect(try store.defaultPolicy(for: .init("foreign")).revision == "0")
    }

    @Test func serializedGlobalPolicyRequiresPrincipalWideManagementAccess() async throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        var account = LinkHarness.existing()
        account.isEnabled = false
        try registry.save(account)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ChatService(
            registry: registry, storage: SQLiteServiceStorageFactory(directory: directory),
            providers: TestProviders()
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: account.principalID, deviceID: .init("device"), sessionID: .init("session"),
            accounts: [], hasAllAccountAccess: true
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        let request = try ServiceRequest(
            header: .init(requestID: .init("set")),
            payload: SetDefaultPolicy(
                rule: .init(sound: .system),
                expectedRevision: "0"
            )
        )
        let response = try await transport.exchange(request)
        let result = try response.value(for: SetDefaultPolicy.self)
        #expect(result.settings.resolvedGlobal.sound == .system)
        #expect(try registry.policy(for: account).settings.resolvedGlobal.sound == .system)
        let restricted = InProcessChatTransport(endpoint: service, context: .init(
            principalID: account.principalID, deviceID: .init("device"), sessionID: .init("other"),
            accounts: [account.id]
        ))
        _ = try await restricted.negotiate(.current)
        let refused = try await restricted.exchange(request)
        #expect(throws: ServiceFailure.notAuthorized) { try refused.value(for: SetDefaultPolicy.self) }
        await service.shutdown()
    }
}
