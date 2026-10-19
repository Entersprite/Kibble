import ChatAPI
import ChatKit
import Foundation
import Synchronization
import Testing
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct PolicyReplicaTests {
    private let binding = PolicyReplicaBinding(
        service: ServiceInstanceID("service"),
        account: ConnectedAccountID("account"),
        revision: ServiceAccountRevision("binding"),
        identity: Member.ID("self")
    )

    @Test func coldReplicaWithholdsAndRefusesEditsUntilCanonicalRead() throws {
        let cache = try makeCache()
        #expect(!cache.snapshot.isReady)
        #expect(!cache.snapshot.canEdit)
        #expect(throws: ServiceFailure.policyUnavailable) { try cache.save(NotificationSettings()) }
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        #expect(cache.snapshot.isReady)
        #expect(cache.snapshot.canEdit)
    }

    @Test func pendingEditsSurviveRestartButValidationDoesNot() throws {
        let storage = PolicyMemoryStorage()
        let cache = try makeCache(storage)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        try cache.save(settings(NotificationRule(readReceipts: false)))
        #expect(!cache.snapshot.isReady)
        let restarted = try makeCache(storage)
        #expect(!restarted.snapshot.isReady)
        #expect(restarted.snapshot.canEdit)
        #expect(try restarted.writeRequest()?.settings.resolvedGlobal.readReceipts == false)
    }

    @Test func rebasePreservesRemotePrivacyAndUnknownFieldsInSameRule() throws {
        let cache = try makeCache()
        try cache.accept(
            AccountPolicy(revision: "0", settings: settings(NotificationRule())),
            invalidation: 0
        )
        try cache.save(settings(NotificationRule(delivery: .off)))
        var remote = NotificationRule(readReceipts: false)
        remote.unrecognisedFields["future"] = .object(["extra": .null])
        try cache.accept(AccountPolicy(revision: "1", settings: settings(remote)), invalidation: 0)
        let rebased = try #require(try cache.writeRequest())
        #expect(rebased.expectedRevision == "1")
        #expect(rebased.settings.resolvedGlobal.delivery == .off)
        #expect(!rebased.settings.resolvedGlobal.readReceipts)
        #expect(rebased.settings.rule(for: .global)?.unrecognisedFields == remote.unrecognisedFields)
    }

    @Test func undoRemovesOnlyThatFieldsIntentBeforeRemoteRebase() throws {
        let cache = try makeCache()
        try cache.accept(
            AccountPolicy(revision: "0", settings: settings(NotificationRule())),
            invalidation: 0
        )
        try cache.save(settings(NotificationRule(delivery: .off, readReceipts: false)))
        try cache.save(settings(NotificationRule(readReceipts: false)))
        try cache.accept(
            AccountPolicy(revision: "1", settings: settings(NotificationRule(delivery: .banner))),
            invalidation: 0
        )
        let rebased = try #require(try cache.writeRequest())
        #expect(rebased.settings.resolvedGlobal.delivery == .banner)
        #expect(!rebased.settings.resolvedGlobal.readReceipts)
    }

    @Test func lateAcknowledgementPreservesNewerLocalEditAndLostReplyReconciles() throws {
        let cache = try makeCache()
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        try cache.save(settings(NotificationRule(delivery: .off)))
        let submitted = try #require(try cache.writeRequest())
        try cache.save(settings(NotificationRule(delivery: .banner)))
        try cache.accept(AccountPolicy(revision: "1", settings: submitted.settings), invalidation: 0)
        #expect(!cache.snapshot.isReady)
        let newest = try #require(try cache.writeRequest())
        #expect(newest.settings.resolvedGlobal.delivery == .banner)
        try cache.accept(AccountPolicy(revision: "2", settings: newest.settings), invalidation: 0)
        #expect(cache.snapshot.isReady)
        #expect(try cache.writeRequest() == nil)
    }

    @Test func failedPersistenceRetainsIntentAndCannotGrantPrivacy() throws {
        let storage = PolicyMemoryStorage()
        let cache = try makeCache(storage)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        storage.refuse(true)
        #expect(throws: ServiceFailure.internalFailure) {
            try cache.save(settings(NotificationRule(delivery: .off)))
        }
        #expect(!cache.snapshot.isReady)
        #expect(cache.snapshot.settings.resolvedGlobal.delivery == .off)
        #expect(storage.document?.acknowledged?.revision == "0")
        #expect(cache.snapshot.error != nil)
        storage.refuse(false)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        #expect(!cache.snapshot.isReady)
        #expect(try cache.writeRequest()?.settings.resolvedGlobal.delivery == .off)
    }

    @Test func metadataInvalidationFencesAnAlreadyRunningRead() throws {
        let cache = try makeCache()
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        cache.invalidate(revision: "1")
        #expect(!cache.snapshot.isReady)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        #expect(!cache.snapshot.isReady)
        try cache.accept(AccountPolicy(revision: "1", settings: .init()), invalidation: 0)
        #expect(cache.snapshot.isReady)
    }

    @Test func missingControlStreamWithholdsEvenAfterSuccessfulPolicyQueryUntilRevalidated() throws {
        let cache = try makeCache()
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        cache.setControlAvailable(false)
        try cache.accept(
            AccountPolicy(revision: "0", settings: .init()),
            invalidation: cache.work.invalidation
        )
        #expect(!cache.isReady)
        cache.setControlAvailable(true)
        #expect(!cache.isReady)
        try cache.accept(
            AccountPolicy(revision: "0", settings: .init()),
            invalidation: cache.work.invalidation
        )
        #expect(cache.isReady)
    }

    @Test func closedCacheRejectsLateAcknowledgementsAndEditsWithoutWriting() throws {
        let storage = PolicyMemoryStorage()
        let cache = try makeCache(storage)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        let count = storage.writeCount
        cache.close()
        #expect(throws: CancellationError.self) {
            try cache.accept(AccountPolicy(revision: "1", settings: .init()), invalidation: 0)
        }
        #expect(throws: ServiceFailure.policyUnavailable) { try cache.save(NotificationSettings()) }
        #expect(storage.writeCount == count)
        #expect(!cache.snapshot.canEdit)
    }

    @Test func unknownValueRefusesTargetedReplacementAndForeignBindingRefusesCache() throws {
        let storage = PolicyMemoryStorage()
        let cache = try makeCache(storage)
        let future = NotificationSettings(records: [SettingsRecord(
            scope: .global,
            value: .unknown(
                type: "future",
                payload: .object(["extra": .string("retained")])
            ),
            modifiedAt: Date(),
            modifiedBy: "other"
        )])
        try cache.accept(AccountPolicy(revision: "1", settings: future), invalidation: 0)
        #expect(throws: ServiceFailure.policyUnavailable) {
            try cache.save(settings(NotificationRule(delivery: .off)))
        }
        let foreign = PolicyReplicaBinding(
            service: ServiceInstanceID("other"),
            account: binding.account,
            revision: binding.revision,
            identity: binding.identity
        )
        #expect(throws: ServiceFailure.policyUnavailable) {
            try PolicyReplicaCache(binding: foreign, deviceID: "device", storage: storage)
        }
        #expect(storage.document?.acknowledged?.settings == future)
    }

    @Test func observersAreIndependentAndNullUnknownFieldSurvivesDurableReencoding() async throws {
        let storage = PolicyMemoryStorage()
        let cache = try makeCache(storage)
        let stream = cache.snapshots()
        let canceled = Task { for await _ in stream {} }
        canceled.cancel(); await canceled.value
        var second = cache.snapshots().makeAsyncIterator()
        #expect(await second.next()?.isReady == false)
        try cache.accept(AccountPolicy(revision: "0", settings: .init()), invalidation: 0)
        var rule = NotificationRule(delivery: .off)
        rule.unrecognisedFields["futureNull"] = .null
        try cache.save(settings(rule))
        let bytes = try ServiceCodec.encode(#require(storage.document))
        let reencoded = try ServiceCodec.decode(PolicyReplicaDocument.self, from: bytes)
        #expect(try reencoded.effectiveSettings().rule(for: .global)?
            .unrecognisedFields["futureNull"] == .null)
        cache.close()
    }

    private func makeCache(_ storage: PolicyMemoryStorage = PolicyMemoryStorage()) throws
        -> PolicyReplicaCache {
        try PolicyReplicaCache(binding: binding, deviceID: "device", storage: storage)
    }

    private func settings(_ rule: NotificationRule) -> NotificationSettings {
        var settings = NotificationSettings()
        settings.setRule(rule, for: .global, at: Date(timeIntervalSince1970: 1_700_000_000), by: "device")
        return settings
    }
}

final class PolicyMemoryStorage: PolicyReplicaStorage {
    private struct State { var document: PolicyReplicaDocument?; var refused = false; var writes = 0 }
    private let state = Mutex(State())
    var document: PolicyReplicaDocument? {
        state.withLock { $0.document }
    }

    var writeCount: Int {
        state.withLock { $0.writes }
    }

    func refuse(_ refused: Bool) {
        state.withLock { $0.refused = refused }
    }

    func load() -> PolicyReplicaDocument? {
        document
    }

    func save(_ document: PolicyReplicaDocument) throws {
        try state.withLock {
            guard !$0.refused else { throw ServiceFailure.internalFailure }
            $0.document = document; $0.writes += 1
        }
    }
}
