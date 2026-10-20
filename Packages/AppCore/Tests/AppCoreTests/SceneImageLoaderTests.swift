import ChatKit
import Foundation
import Synchronization
import Testing
@testable import AppCore

private actor HeldSceneImage {
    var waiting = false
    var waiter: CheckedContinuation<Data, Never>?
    func read() async -> Data {
        waiting = true
        return await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume(returning: Data("old".utf8)); waiter = nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SceneImageLoaderTests {
    @Test func retainedLoadersCannotReadOrPublishForAReplacementCache() async throws {
        let services = try FakeLaunchServices(backendCapabilities: .init(canFetchRemoteImages: true))
        let environment = AppEnvironment(services: services)
        await environment.start()
        let held = HeldSceneImage()
        let old = AttachmentCache(
            directory: nil,
            remoteFetch: { _ in await held.read() },
            fetch: { _, _ in Data() }
        )
        environment.attachments = old
        let loader = try #require(environment.imageLoader)
        #expect(environment.actions.imageLoader?.id == loader.id)
        let url = try #require(URL(string: "https://acme.example/shared.png"))
        let reading = Task { try await loader.load(url) }
        guard await eventually({ await held.waiting }) else {
            await held.release(); _ = await reading.result
            await environment.signOut()
            throw AppEnvironment.NoSession()
        }
        let newReads = Mutex(0)
        let replacement = AttachmentCache(directory: nil, remoteFetch: { _ in
            newReads.withLock { $0 += 1 }
            return Data("new".utf8)
        }, fetch: { _, _ in Data() })
        environment.attachments = replacement
        await held.release()
        await #expect(throws: AppEnvironment.NoSession.self) { try await reading.value }
        await #expect(throws: AppEnvironment.NoSession.self) { try await loader.load(url) }
        #expect(newReads.withLock { $0 } == 0)
        let current = try #require(environment.imageLoader)
        #expect(current.id != loader.id)
        #expect(try await current.load(url) == Data("new".utf8))
        try await environment.detachClient(erasingPrivateData: false)
        #expect(environment.imageLoader == nil)
        await #expect(throws: AppEnvironment.NoSession.self) { try await current.load(url) }
        await old.retire()
    }

    @Test func missingCapabilityOffersNoImageLoader() async throws {
        let services = try FakeLaunchServices(backendCapabilities: .init())
        let environment = AppEnvironment(services: services)
        await environment.start()
        #expect(environment.imageLoader == nil)
        #expect(environment.actions.imageLoader == nil)
        #expect(environment.actions.loadRemoteImage == nil)
        await environment.signOut()
    }
}
