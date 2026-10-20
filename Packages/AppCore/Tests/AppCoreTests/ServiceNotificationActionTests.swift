import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import AppCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ServiceNotificationActionTests {
    private let scope = AccountNotificationScope(
        service: .init("service"), account: .init("second"), revision: .init("binding")
    )

    @Test func backgroundReadUsesOnlyTheTargetAccountWithoutAReplica() async throws {
        let transport = NotificationActionTransport()
        let actions = ServiceNotificationActions(
            service: scope.service, client: AccountClient(transport: transport), device: "native"
        )
        var failures = 0
        actions.onFailure = { failures += 1 }
        #expect(actions.handle(.init(scope: scope, response: .markRead(.init("same")))))
        try await wait { await transport.commands.count == 1 }
        let commands = await transport.commands
        #expect(commands.first == .markRead(
            conversationID: .init("same"), upTo: Date(timeIntervalSince1970: 10)
        ))
        let headers = await transport.scopedHeaders
        #expect(headers.count == 2)
        #expect(headers.allSatisfy { $0.accountID == scope.account && $0.accountRevision == scope.revision })
        #expect(failures == 0)
        await actions.stop()
    }

    @Test func muteRetriesAConflictAndPreservesExistingPrivacyAndUnknownFields() async throws {
        let transport = NotificationActionTransport()
        let actions = ServiceNotificationActions(
            service: scope.service, client: AccountClient(transport: transport), device: "native"
        )
        #expect(actions.handle(.init(scope: scope, response: .mute(.init("same")))))
        try await wait { await transport.saves == 1 }
        let policy = await transport.policy
        let rule = try #require(policy.settings.rule(for: .conversation(.init("same"))))
        #expect(rule.delivery == .off)
        #expect(rule.readReceipts == false && rule.sharesTyping == false && rule.showsPreview == false)
        #expect(rule.unrecognisedFields["future"] == .string("retained"))
        #expect(await transport.policyReads == 2)
        await actions.stop()
    }

    @Test func foreignAndReplacedScopesAreRefusedAndStoppedActionsCannotDispatch() async throws {
        let transport = NotificationActionTransport()
        let actions = ServiceNotificationActions(
            service: scope.service, client: AccountClient(transport: transport), device: "native"
        )
        var failures = 0
        actions.onFailure = { failures += 1 }
        #expect(actions.handle(.init(scope: .init(
            service: .init("foreign"), account: scope.account, revision: scope.revision
        ), response: .markRead(.init("same")))))
        #expect(actions.handle(.init(scope: .init(
            service: scope.service, account: scope.account, revision: .init("old")
        ), response: .markRead(.init("same")))))
        try await wait { failures == 1 }
        #expect(await transport.scopedHeaders.isEmpty)
        await actions.stop()
        #expect(actions.handle(.init(scope: scope, response: .mute(.init("same")))))
        #expect(await transport.scopedHeaders.isEmpty)
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ServiceFailure.deadlineExceeded
    }
}

private actor NotificationActionTransport: ServiceTransport {
    private(set) var commands: [ChatCommand] = []
    private(set) var scopedHeaders: [ServiceRequestHeader] = []
    private(set) var saves = 0
    private(set) var policyReads = 0
    private var conflict = true
    private(set) var policy: AccountPolicy

    init() {
        var settings = NotificationSettings()
        var rule = NotificationRule(showsPreview: false, sharesTyping: false, readReceipts: false)
        rule.unrecognisedFields["future"] = .string("retained")
        settings.setRule(rule, for: .conversation(.init("same")), at: .distantPast, by: "seed")
        policy = .init(revision: "1", settings: settings)
    }

    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func exchange(_ request: ServiceRequest) throws -> ServiceResponse {
        if request.header.accountID != nil {
            scopedHeaders.append(request.header)
        }
        let value: JSONValue
        switch request.operation {
        case ListAccounts.operation:
            value = try ServiceCodec.value([workspaceAccount("first"), workspaceAccount("second")])
        case LoadMessages.operation:
            let conversation = try request.decodePayload(LoadMessages.self).conversationID
            let messages = [
                message(conversation, at: 10),
                message(conversation, at: 30, reply: true),
                message(conversation, at: 40, deleted: true)
            ]
            value = try ServiceCodec.value(MessagePage(messages: messages, nextCursor: nil, isComplete: true))
        case SendCommand.operation:
            let payload = try request.decodePayload(SendCommand.self)
            commands.append(payload.command)
            value = try ServiceCodec.value(ServiceOperation(id: payload.operationID, state: "succeeded"))
        case GetAccountPolicy.operation:
            policyReads += 1
            value = try ServiceCodec.value(policy)
        case SetAccountPolicy.operation:
            let payload = try request.decodePayload(SetAccountPolicy.self)
            if conflict {
                conflict = false
                policy = .init(revision: "2", settings: policy.settings)
                return ServiceResponse(replyingTo: request, result: .failure(.revisionConflict))
            }
            guard payload.expectedRevision == policy.revision else { throw ServiceFailure.revisionConflict }
            saves += 1
            policy = .init(revision: "3", settings: payload.settings)
            value = try ServiceCodec.value(policy)
        default: throw ServiceFailure.unsupportedOperation
        }
        return ServiceResponse(replyingTo: request, result: .success(value))
    }

    private func message(
        _ conversation: Conversation.ID, at seconds: Double, reply: Bool = false, deleted: Bool = false
    ) -> Message {
        Message(
            id: .init(String(seconds)),
            conversationID: conversation,
            threadID: .init("thread"),
            sender: .init("peer"),
            text: "message",
            createdAt: Date(timeIntervalSince1970: seconds),
            isDeleted: deleted,
            isReply: reply
        )
    }
}
