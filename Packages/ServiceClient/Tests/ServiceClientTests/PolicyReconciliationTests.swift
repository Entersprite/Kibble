import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PolicyReconciliationTests {
    @Test func conflictRebasesEditedDeliveryWithoutUndoingAnotherClientsReceiptChoice() async throws {
        let harness = try await ClientHarness.make()
        let transport = ScriptedPolicyTransport(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let client = AccountClient(transport: transport)
        let cache = try await makeCache(harness, client: client)
        let controller = PolicyReplicaController(client: client, cache: cache)
        await controller.start()
        try await eventually { cache.snapshot.isReady }
        await transport.configure(.conflict)
        var edit = cache.snapshot.settings
        edit.setRule(NotificationRule(delivery: .off), for: .global, at: Date(), by: "device")
        try cache.save(edit)
        try await eventually { cache.snapshot.isReady && !cache.snapshot.settings.resolvedGlobal.readReceipts
        }
        #expect(cache.snapshot.settings.resolvedGlobal.delivery == .off)
        #expect(await transport.writes == 2)
        await controller.stop()
        await harness.service.shutdown()
    }

    @Test func lostWriteReplyIsAcknowledgedByReadWithoutDuplicateWrite() async throws {
        let harness = try await ClientHarness.make()
        let transport = ScriptedPolicyTransport(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let client = AccountClient(transport: transport)
        let cache = try await makeCache(harness, client: client)
        let controller = PolicyReplicaController(client: client, cache: cache)
        await controller.start()
        try await eventually { cache.snapshot.isReady }
        await transport.configure(.loseReply)
        var edit = cache.snapshot.settings
        edit.setRule(NotificationRule(readReceipts: false), for: .global, at: Date(), by: "device")
        try cache.save(edit)
        try await eventually { cache.snapshot.isReady && !cache.snapshot.settings.resolvedGlobal.readReceipts
        }
        #expect(await transport.writes == 1)
        await controller.stop()
        #expect(!cache.snapshot.isReady)
        await harness.service.shutdown()
    }

    @Test func offlinePendingEditResumesAfterControllerAndCacheRestart() async throws {
        let harness = try await ClientHarness.make()
        let transport = ScriptedPolicyTransport(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let client = AccountClient(transport: transport)
        let storage = PolicyMemoryStorage()
        let first = try await makeCache(harness, client: client, storage: storage)
        let firstController = PolicyReplicaController(client: client, cache: first)
        await firstController.start()
        try await eventually { first.snapshot.isReady }
        await transport.setOffline(true)
        var edit = first.snapshot.settings
        edit.setRule(NotificationRule(readReceipts: false), for: .global, at: Date(), by: "device")
        try first.save(edit)
        try await eventually { first.snapshot.error != nil }
        await firstController.stop()
        let restarted = try await makeCache(harness, client: AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service, context: harness.context
        )), storage: storage)
        #expect(!restarted.snapshot.isReady)
        await transport.setOffline(false)
        let secondController = PolicyReplicaController(client: client, cache: restarted)
        await secondController.start()
        try await eventually { restarted.snapshot.isReady }
        #expect(!restarted.snapshot.settings.resolvedGlobal.readReceipts)
        #expect(await transport.writes == 1)
        await secondController.stop()
        await harness.service.shutdown()
    }

    private func makeCache(
        _ harness: ClientHarness,
        client: AccountClient,
        storage: PolicyMemoryStorage = PolicyMemoryStorage()
    ) async throws
        -> PolicyReplicaCache {
        let info = try await client.serviceInfo()
        let revision = try #require(harness.first.revision)
        return try PolicyReplicaCache(binding: PolicyReplicaBinding(
            service: info.instanceID, account: harness.first.id, revision: revision,
            identity: harness.first.selfID
        ), deviceID: "device", storage: storage)
    }
}

private actor ScriptedPolicyTransport: ServiceTransport {
    enum Behaviour { case ordinary, conflict, loseReply }
    let base: any ServiceTransport
    private var behaviour = Behaviour.ordinary
    private var offline = false
    private(set) var writes = 0

    init(base: any ServiceTransport) {
        self.base = base
    }

    func configure(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func setOffline(_ offline: Bool) {
        self.offline = offline
    }

    func negotiate(_ version: ServiceAPIVersion) async throws -> ServiceAPIVersion {
        try await base.negotiate(version)
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        guard !offline else { throw ServiceFailure.overloaded }
        guard request.operation == SetAccountPolicy.operation else { return try await base.exchange(request) }
        writes += 1
        let action = behaviour
        behaviour = .ordinary
        if action == .conflict {
            let current = try await base.exchange(copy(GetAccountPolicy(), request: request))
                .value(for: GetAccountPolicy.self)
            var settings = current.settings
            settings.setRule(
                NotificationRule(readReceipts: false),
                for: .global,
                at: Date(),
                by: "other-client"
            )
            _ = try await base.exchange(copy(
                SetAccountPolicy(settings: settings, expectedRevision: current.revision),
                request: request
            ))
            .value(for: SetAccountPolicy.self)
        }
        let response = try await base.exchange(request)
        if action == .loseReply {
            throw ServiceFailure.deadlineExceeded
        }
        return response
    }

    private func copy(
        _ payload: some ServiceRequestPayload,
        request: ServiceRequest
    ) throws -> ServiceRequest {
        try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID(UUID().uuidString),
                accountID: request.header.accountID,
                accountRevision: request.header.accountRevision,
                deadline: Date().addingTimeInterval(10)
            ),
            payload: payload
        )
    }
}
