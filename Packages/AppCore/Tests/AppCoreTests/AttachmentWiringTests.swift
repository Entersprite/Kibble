import ChatKit
import Foundation
import Testing
@testable import AppCore

/// The attachment cache, as `AppEnvironment` builds it per session and offers
/// it to the scene: the actions exist only when the backend can fetch, they
/// go through the cache, and sign-out takes the cache with it.
@MainActor
struct AttachmentWiringTests {
    private static let image = ChatKit.Attachment(id: "token-1", name: "a.png", contentType: "image/png")

    private func running(canFetch: Bool) async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canFetchAttachments: canFetch)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return (environment, services)
        }
        return (environment, services)
    }

    private func files(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    @Test func withoutTheCapabilityNoAttachmentActionIsOffered() async throws {
        let (environment, services) = try await running(canFetch: false)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        #expect(environment.actions.loadAttachment == nil)
        #expect(environment.actions.openAttachment == nil)
    }

    @Test func loadingGoesThroughTheCacheToTheBackend() async throws {
        let (environment, services) = try await running(canFetch: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let load = try #require(environment.actions.loadAttachment)
        let first = try await load(Self.image, .preview)
        let second = try await load(Self.image, .preview)
        #expect(first == Data("bytes:token-1/preview".utf8))
        #expect(second == first)
        #expect(services.backend.attachmentFetches == ["token-1/preview"])
    }

    @Test func openingWritesTheOriginalUnderTheSessionsDirectory() async throws {
        let (environment, services) = try await running(canFetch: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let open = try #require(environment.actions.openAttachment)
        let url = try await open(Self.image)
        #expect(url.resolvingSymlinksInPath().path()
            .hasPrefix(services.attachmentDirectory.resolvingSymlinksInPath().path()))
        #expect(try Data(contentsOf: url) == Data("bytes:token-1/original".utf8))
    }

    @Test func signingOutErasesTheCacheFromDisk() async throws {
        let (environment, services) = try await running(canFetch: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        _ = try await environment.actions.loadAttachment?(Self.image, .preview)
        // Positive control: there was something on disk to erase.
        try #require(!files(in: services.attachmentDirectory).isEmpty)

        await environment.signOut()
        #expect(files(in: services.attachmentDirectory).isEmpty)
    }

    /// A view still on screen during sign-out holds the closure it was given.
    @Test func anActionHeldAcrossSignOutCannotFetchForTheOldSession() async throws {
        let (environment, services) = try await running(canFetch: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let load = try #require(environment.actions.loadAttachment)
        await environment.signOut()
        await #expect(throws: (any Error).self) {
            _ = try await load(Self.image, .preview)
        }
        #expect(services.backend.attachmentFetches.isEmpty)
        #expect(files(in: services.attachmentDirectory).isEmpty)
    }
}
