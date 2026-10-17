import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

extension LocalBridgeBackend {
    func setMeetingClock(_ now: Date) {
        meetingMetadataNow = { now }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MeetingMetadataCacheTests {
    let scope = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 200)

    @Test(arguments: [false, true])
    func relaunchReusesPositiveAndNegativeResultsWithoutRequests(unsupported: Bool) async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = MeetingDetailTransport()
        if unsupported {
            await transport.setUnsupported()
        }
        let backend = try await connected(transport, url: url, at: now)
        let log = MeetingEventLog()
        let reader = Task { for await event in backend.events {
            await log.record(event)
        } }
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 2 }
        #expect(await backend.meetingMetadata.loading)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        try await wait { await log.loading == [true, false] }
        await backend.disconnect()
        reader.cancel()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let warmTransport = MeetingDetailTransport()
        await warmTransport.revise() // A message revision alone does not expire metadata.
        let warm = try await connected(warmTransport, url: url, at: now.addingTimeInterval(60))
        let warmLog = MeetingEventLog()
        let warmReader = Task { for await event in warm.events {
            await warmLog.record(event)
        } }
        let conversations = try await warm.loadConversations()
        #expect(conversations.allSatisfy { ($0.meeting == nil) == unsupported })
        #expect(await warm.meetingMetadata.cache.count == 2)
        #expect(await warmTransport.requests == 0)
        #expect(await warm.meetingMetadata.task == nil)
        #expect(await !warm.meetingMetadata.loading)
        if unsupported {
            try await wait { await warmLog.count == 2 }
            _ = try await warm.loadConversations()
            #expect(await warmLog.count == 2)
        }
        #expect(await warmLog.loading.isEmpty)
        warmReader.cancel()
        await warm.disconnect()
    }

    @Test func staleResultsStayVisibleDuringRefreshAndExplicitWithdrawalIsSaved() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url)
        let transport = MeetingDetailTransport()
        await transport.setUnsupported()
        let later = now.addingTimeInterval(86401)
        let backend = try await connected(transport, url: url, at: later)
        let conversations = try await backend.loadConversations()
        #expect(conversations.allSatisfy { $0.meeting != nil })
        try await wait { await transport.active == 2 }
        #expect(await !backend.meetingMetadata.loading)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.values.allSatisfy { $0.meeting == nil })
        await backend.disconnect()
        let nextTransport = MeetingDetailTransport()
        let next = try await connected(nextTransport, url: url, at: later.addingTimeInterval(60))
        #expect(try await next.loadConversations().allSatisfy { $0.meeting == nil })
        #expect(await nextTransport.requests == 0)
        await next.disconnect()
    }

    @Test func failedRefreshPreservesTheLastSuccessfulResultAndItsAge() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url)
        let transport = MeetingDetailTransport()
        await transport.setFailure(true)
        await transport.release()
        let backend = try await connected(transport, url: url, at: now.addingTimeInterval(86401))
        #expect(try await backend.loadConversations().allSatisfy { $0.meeting != nil })
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.values.allSatisfy {
            $0.meeting != nil && $0.checkedAt == now
        })
        #expect(await !backend.meetingMetadata.loading)
        await backend.disconnect()
    }

    @Test func expiredNegativeResultIsRecheckedAndCanBecomeRecurring() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url, unsupported: true)
        let transport = MeetingDetailTransport()
        let backend = try await connected(transport, url: url, at: now.addingTimeInterval(21601))
        #expect(try await backend.loadConversations().allSatisfy { $0.meeting == nil })
        try await wait { await transport.active == 2 }
        #expect(await !backend.meetingMetadata.loading)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.values.allSatisfy { $0.meeting != nil })
        await backend.disconnect()
    }

    @Test func changedMeetingSummaryRefreshesEvenAFreshCache() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url)
        let transport = MeetingDetailTransport()
        await transport.revise(metadataChanged: true)
        let backend = try await connected(transport, url: url, at: now.addingTimeInterval(60))
        let conversations = try await backend.loadConversations()
        #expect(conversations.allSatisfy { $0.meeting != nil })
        try await wait { await transport.active == 2 }
        #expect(await !backend.meetingMetadata.loading)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await backend.meetingMetadata.cache.values.allSatisfy { $0.key.revision == 2 })
        await backend.disconnect()
    }

    @Test(arguments: ["different-login", "corrupt"])
    func unusableCacheStartsColdWithoutLeakingOldGroups(reason: String) async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url)
        if reason == "corrupt" {
            try Data("broken".utf8).write(to: url)
        }
        let transport = MeetingDetailTransport()
        let backend = try await connected(
            transport,
            url: url,
            at: now,
            scope: reason == "different-login" ? scope
                .addingTimeInterval(1) : scope
        )
        let conversations = try await backend.loadConversations()
        #expect(conversations.allSatisfy { $0.meeting == nil })
        try await wait { await transport.active == 2 }
        #expect(await backend.meetingMetadata.loading)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        await backend.disconnect()
    }

    @Test func resultsSavedWithoutAGroupingScopeAreLookedUpAgain() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(url)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.contains { ($0["meeting"] as? [String: Any])?["seriesScope"] != nil })
        json["entries"] = entries.map { entry in
            var entry = entry
            if var meeting = entry["meeting"] as? [String: Any] {
                meeting["seriesScope"] = nil
                entry["meeting"] = meeting
            }
            return entry
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let transport = MeetingDetailTransport()
        await transport.release()
        let warm = try await connected(transport, url: url, at: now.addingTimeInterval(60))
        _ = try await warm.loadConversations()
        try await wait { await warm.meetingMetadata.task == nil }
        #expect(await transport.requests == 2)
        let scopes = await warm.meetingMetadata.cache.values.map { $0.meeting?.seriesScope }
        #expect(scopes.count == 2 && scopes.allSatisfy { $0 != nil })
        await warm.disconnect()
    }

    @Test func lateResponseCannotRecreateErasedCache() async throws {
        let url = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = MeetingDetailTransport()
        let backend = try await connected(transport, url: url, at: now)
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 2 }
        let pending = await backend.meetingMetadata.task
        await backend.disconnect()
        try FileManager.default.removeItem(at: url)
        await transport.release()
        await pending?.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await backend.meetingMetadata.cache.isEmpty)
    }

    @Test func requestSlotsRefillWithoutWaitingForTheSlowestRequest() async throws {
        let transport = MeetingDetailTransport(count: 8)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        _ = try await backend.loadConversations()
        try await wait { await transport.active == 6 }
        await transport.releaseOne()
        try await wait { await transport.requests == 7 }
        #expect(await transport.maximum == 6)
        await transport.release()
        try await wait { await backend.meetingMetadata.task == nil }
        #expect(await transport.requests == 8)
        await backend.disconnect()
    }

    private func seed(_ url: URL, unsupported: Bool = false) async throws {
        let transport = MeetingDetailTransport()
        if unsupported {
            await transport.setUnsupported()
        }
        await transport.release()
        let backend = try await connected(transport, url: url, at: now)
        _ = try await backend.loadConversations()
        try await wait { await backend.meetingMetadata.task == nil }
        await backend.disconnect()
    }

    private func connected(
        _ transport: MeetingDetailTransport,
        url: URL,
        at now: Date,
        scope: Date? = nil
    ) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        await backend.installMeetingMetadataCache(at: url, scope: scope ?? self.scope)
        await backend.setMeetingClock(now)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }

    private func temporaryCache() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("metadata.json")
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}
