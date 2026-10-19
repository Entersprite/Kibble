import ChatAPI
import ChatKit
import ChatService
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PrivacyAdmissionTests {
    private let conversation = ReconciliationBackend.conversation
    private let date = ReconciliationBackend.date

    @Test func readPrivacyIsEnforcedBeforeDispatchAndRefusalIsDurable() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        try await update(harness, rule: NotificationRule(readReceipts: false), scope: .global)
        let command = SendCommand(operationID: ServiceOperationID("private-read"), command: .markRead(
            conversationID: conversation, upTo: date
        ))
        await #expect(throws: ServiceFailure.privacyDenied) { try await harness.call(command) }
        #expect(await harness.backend.sentCommands.isEmpty)
        let refused = try await harness.call(GetOperation(operationID: command.operationID))
        #expect(refused.state == "failed" && refused.failure == .privacyDenied)
        try await update(harness, rule: NotificationRule(readReceipts: true), scope: .global)
        // Retrying the same refused operation remains the same outcome.
        await #expect(throws: ServiceFailure.privacyDenied) { try await harness.call(command) }
        let allowed = try await harness.call(SendCommand(
            operationID: ServiceOperationID("explicit-new-read"), command: command.command
        ))
        #expect(allowed.state == "succeeded")
        #expect(await harness.backend.sentCommands == [command.command])
        await harness.service.shutdown()
    }

    @Test func scopedOverridesUseTheServiceConversationAndApplyToThreadReads() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        try await update(harness, rule: NotificationRule(readReceipts: false), scope: .global)
        try await update(harness, rule: NotificationRule(readReceipts: true), scope: .section(.spaces))
        let thread = MessageThread.ID("thread")
        let commands: [ChatCommand] = [
            .markThreadRead(conversationID: conversation, threadID: thread, upTo: date),
            .setThreadUnreadMark(conversationID: conversation, threadID: thread, at: nil)
        ]
        for (index, command) in commands.enumerated() {
            _ = try await harness.call(SendCommand(
                operationID: ServiceOperationID("section-\(index)"), command: command
            ))
        }
        try await update(
            harness,
            rule: NotificationRule(readReceipts: false),
            scope: .conversation(conversation)
        )
        for (index, command) in commands.enumerated() {
            await #expect(throws: ServiceFailure.privacyDenied) {
                try await harness.call(SendCommand(
                    operationID: ServiceOperationID("conversation-\(index)"), command: command
                ))
            }
        }
        // An explicit unread mark does not publish a read receipt.
        _ = try await harness.call(SendCommand(
            operationID: ServiceOperationID("unread"),
            command:
            .setThreadUnreadMark(conversationID: conversation, threadID: thread, at: date)
        ))
        #expect(await harness.backend.sentCommands.count == 3)
        await harness.service.shutdown()
    }

    @Test func typingIsDefaultOffAndCanAlwaysBeStoppedAfterConsentChanges() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        let start = ChatCommand.setTyping(conversationID: conversation, threadID: nil, isTyping: true)
        await #expect(throws: ServiceFailure.privacyDenied) {
            try await harness.call(SendHint(command: start))
        }
        try await update(
            harness,
            rule: NotificationRule(sharesTyping: true),
            scope: .conversation(conversation)
        )
        _ = try await harness.call(SendHint(command: start))
        try await update(
            harness,
            rule: NotificationRule(sharesTyping: false),
            scope: .conversation(conversation)
        )
        let stop = ChatCommand.setTyping(conversationID: conversation, threadID: nil, isTyping: false)
        _ = try await harness.call(SendHint(command: stop))
        await #expect(throws: ServiceFailure.privacyDenied) {
            try await harness.call(SendHint(command: start))
        }
        #expect(await harness.backend.sentCommands == [start, stop])
        await harness.service.shutdown()
    }

    @Test func missingConversationCannotFallBackToPermissiveGlobalRules() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        let missing = ChatCommand.markRead(conversationID: Conversation.ID("missing"), upTo: date)
        await #expect(throws: ServiceFailure.privacyDenied) {
            try await harness.call(SendCommand(operationID: ServiceOperationID("missing"), command: missing))
        }
        #expect(await harness.backend.sentCommands.isEmpty)
        #expect(try harness.storage.conversation(conversation)?.kind == .space)
        await harness.service.shutdown()
    }

    @Test func unavailablePolicyRefusesWithoutDispatchAndSameOperationCanRetryAfterRecovery() async throws {
        let policies = RecoverablePrivacyPolicies()
        let harness = try await ReconciliationHarness.make(policies: policies)
        _ = try await harness.call(LoadConversations())
        let command = SendCommand(
            operationID: ServiceOperationID("read"),
            command:
            .markRead(conversationID: conversation, upTo: date)
        )
        await #expect(throws: ServiceFailure.policyUnavailable) { try await harness.call(command) }
        #expect(await harness.backend.sentCommands.isEmpty)
        #expect(try await harness.call(GetOperation(operationID: command.operationID)).state == "accepted")
        policies.setAvailable(true)
        #expect(try await harness.call(command).state == "succeeded")
        #expect(await harness.backend.sentCommands == [command.command])
        await harness.service.shutdown()
    }

    @Test func policyOnOneAccountCannotSuppressAnotherAccountsReceipt() async throws {
        let harness = try await ServiceHarness.make()
        let initial = try await harness.call(GetAccountPolicy(), account: harness.first.id)
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: date, by: "device")
        _ = try await harness.call(
            SetAccountPolicy(settings: settings, expectedRevision: initial.revision),
            account: harness.first.id
        )
        let firstRows = try await harness.call(LoadConversations(), account: harness.first.id)
        _ = try await harness.call(LoadConversations(), account: harness.second.id)
        let id = try #require(firstRows.first?.id)
        let read = SendCommand(
            operationID: ServiceOperationID("same-id"),
            command:
            .markRead(conversationID: id, upTo: date)
        )
        await #expect(throws: ServiceFailure.privacyDenied) {
            try await harness.call(read, account: harness.first.id)
        }
        #expect(try await harness.call(read, account: harness.second.id).state == "succeeded")
        await harness.service.shutdown()
    }

    private func update(
        _ harness: ReconciliationHarness, rule: NotificationRule, scope: SettingsScope
    ) async throws {
        let current = try await harness.call(GetAccountPolicy())
        var settings = current.settings
        settings.setRule(rule, for: scope, at: date, by: "device")
        _ = try await harness.call(SetAccountPolicy(settings: settings, expectedRevision: current.revision))
    }
}

private final class RecoverablePrivacyPolicies: AccountPolicyStore {
    private let available = Mutex(false)
    func setAvailable(_ value: Bool) {
        available.withLock { $0 = value }
    }

    func policy(for account: AccountRecord) throws -> AccountPolicy {
        guard available.withLock({ $0 }) else { throw ServiceFailure.internalFailure }
        return AccountPolicy(revision: "0", settings: NotificationSettings())
    }

    func setPolicy(
        _ settings: NotificationSettings, for account: AccountRecord, expectedRevision: String
    ) throws -> AccountPolicy {
        throw ServiceFailure.unsupportedOperation
    }
}
