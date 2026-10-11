import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Recent searches (search spec §1.2): the newest ten, on this Mac, erased
/// with the account.
struct StoreSearchRecentsTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func newestFirstAndOnePerText() throws {
        let store = try ChatStore.inMemory()
        try store.recordSearch("deploy", at: Self.start)
        try store.recordSearch("invoice", at: Self.start.addingTimeInterval(1))
        try store.recordSearch("deploy", at: Self.start.addingTimeInterval(2))
        #expect(try store.recentSearches(limit: 10) == ["deploy", "invoice"])
    }

    @Test func onlyTheNewestTenAreKept() throws {
        let store = try ChatStore.inMemory()
        for index in 0 ..< 12 {
            try store.recordSearch("q\(index)", at: Self.start.addingTimeInterval(Double(index)))
        }
        let recents = try store.recentSearches(limit: 50)
        #expect(recents.count == 10)
        #expect(recents.first == "q11")
        #expect(!recents.contains("q1"))
    }

    @Test func eraseTakesThem() throws {
        let store = try ChatStore.inMemory()
        try store.recordSearch("deploy", at: Self.start)
        try store.erase()
        #expect(try store.recentSearches(limit: 10).isEmpty)
    }
}
