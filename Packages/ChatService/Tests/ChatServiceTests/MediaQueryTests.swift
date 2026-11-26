import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct MediaQueryTests {
    @Test func aSerializedLateQueryCannotRestoreAnOlderProfileImage() async throws {
        let harness = try await ReconciliationHarness.make()
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let refresh = await runtime.worldRefresh
            return try refresh == nil && !harness.storage.conversations().isEmpty
        }
        let oldURL = try #require(URL(string: "https://images.example/old.png"))
        let newURL = try #require(URL(string: "https://images.example/new.png"))
        var member = Member(id: .init("peer"), kind: .human, avatarURL: oldURL)
        await harness.backend.setSearchMembers([member], hold: true)
        let query = Task { try await harness.call(SearchPeople(query: "peer")) }
        do {
            try await authEventually { await harness.backend.searchHeld }
            member.avatarURL = newURL
            await harness.backend.setSearchMembers([member])
            await harness.backend.emit(.membersResolved([member]))
            let catalog = try #require(harness.storage as? any ServiceMediaCatalog)
            try await authEventually {
                try !catalog.mediaSources(for: .remoteImage(newURL), at: Date()).isEmpty
            }
            await harness.backend.releaseSearch()
            #expect(try await query.value.first?.avatarURL == newURL)
            #expect(try catalog.mediaSources(for: .remoteImage(oldURL), at: Date()).isEmpty)
            #expect(try !catalog.mediaSources(for: .remoteImage(newURL), at: Date()).isEmpty)
        } catch {
            await harness.backend.releaseSearch()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }
}
