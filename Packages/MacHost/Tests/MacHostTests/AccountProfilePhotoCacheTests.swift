import AppCore
import ChatAPI
import Foundation
import Testing
@testable import MacHost

@MainActor
struct AccountProfilePhotoCacheTests {
    @Test func photosSurviveRelaunchDisableAndSignOutButDisappearOnRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AccountProfilePhotoCache(directory: directory)
        let account = summary()
        try cache.prepare([account])
        let photo = try makePhoto([1, 2, 3])
        cache.save(photo, for: account)
        let restarted = AccountProfilePhotoCache(directory: directory)
        #expect(restarted.load([summary(enabled: false)])[account.id] == photo)
        #expect(restarted.load([summary(authentication: "required")])[account.id] == photo)
        try restarted.prepare([])
        #expect(restarted.load([account])[account.id] == nil)
    }

    @Test func aRetiredBindingOrAccountCannotRepopulateThePhoto() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AccountProfilePhotoCache(directory: directory)
        let old = summary()
        let photo = try makePhoto([9])
        try cache.prepare([summary(revision: "new")])
        cache.save(photo, for: old)
        #expect(cache.load([summary(revision: "new")]).isEmpty)
        cache.update([])
        cache.save(photo, for: old)
        #expect(cache.load([old]).isEmpty)
    }

    @Test func boundsAndForeignIdentityNeverProduceAFace() throws {
        #expect(
            try AccountProfilePhoto(url: #require(URL(string: "https://example.invalid")), data: Data()) ==
                nil
        )
        #expect(try AccountProfilePhoto(
            url: #require(URL(string: "https://example.invalid")),
            data: Data(repeating: 1, count: AccountProfilePhoto.maximumBytes + 1)
        ) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AccountProfilePhotoCache(directory: directory)
        let account = summary()
        try cache.prepare([account])
        let photo = try makePhoto([1])
        cache.save(photo, for: account)
        #expect(cache.load([summary(identity: "other")]).isEmpty)
    }

    private func makePhoto(_ bytes: [UInt8]) throws -> AccountProfilePhoto {
        let url = try #require(URL(string: "https://example.invalid/photo"))
        let candidate = AccountProfilePhoto(url: url, data: Data(bytes))
        return try #require(candidate)
    }

    private func summary(
        enabled: Bool = true,
        authentication: String? = nil,
        revision: String = "one",
        identity: String = "self"
    ) -> AccountSummary {
        AccountSummary(
            id: .init("account"),
            selfID: .init(identity),
            label: "Account",
            connection: .idle,
            isEnabled: enabled,
            revision: .init(revision),
            authenticationState: authentication
        )
    }
}
