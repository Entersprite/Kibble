import AppCore
import ChatKit
import Foundation
import Testing

/// Counts fetches, and can hold one until a test releases it.
private actor RemoteRecorder {
    private(set) var calls: [URL] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func hold() {
        holding = true
    }

    func release() {
        holding = false
        for continuation in held {
            continuation.resume()
        }
        held = []
    }

    var heldCount: Int {
        held.count
    }

    func fetch(_ url: URL) async throws -> Data {
        calls.append(url)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return Data(url.absoluteString.utf8)
    }
}

/// `AttachmentCache.remoteImageData(for:)` (links spec §6): one fetch, kept on
/// disk, and erased with everything else at sign-out.
@Suite(.timeLimit(.minutes(1)))
struct RemoteImageCacheTests {
    private static let url = URL(string: "https://lh3.googleusercontent.com/p-1")!

    private static func cache(_ recorder: RemoteRecorder, directory: URL?) -> AttachmentCache {
        AttachmentCache(
            directory: directory,
            remoteFetch: { try await recorder.fetch($0) },
            fetch: { _, _ in Data() }
        )
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "remote-cache-tests-\(UUID().uuidString)")
    }

    @Test func oneFetchServesSimultaneousCallersAndTheDiskServesTheNextCache() async throws {
        let recorder = RemoteRecorder()
        let directory = Self.directory()
        let cache = Self.cache(recorder, directory: directory)
        async let first = cache.remoteImageData(for: Self.url)
        async let second = cache.remoteImageData(for: Self.url)
        #expect(try await first == second)
        #expect(await recorder.calls.count == 1)
        let fresh = Self.cache(recorder, directory: directory)
        _ = try await fresh.remoteImageData(for: Self.url)
        #expect(await recorder.calls.count == 1)
    }

    /// Review Focus 4: sign-out mid-fetch keeps nothing.
    @Test func anEraseDuringAFetchThrowsAndKeepsNothing() async throws {
        let recorder = RemoteRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: Self.directory())
        let pending = Task { try await cache.remoteImageData(for: Self.url) }
        // Bounded, and it suspends on something cancellable (CLAUDE.md).
        for _ in 0 ..< 1000 where await recorder.heldCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await recorder.heldCount == 1)
        await cache.erase()
        await recorder.release()
        await #expect(throws: AttachmentCache.Erased.self) { _ = try await pending.value }
        await #expect(throws: AttachmentCache.Erased.self) {
            _ = try await cache.remoteImageData(for: Self.url)
        }
    }

    @Test func withoutAFetchItRefuses() async {
        let cache = AttachmentCache(directory: nil, fetch: { _, _ in Data() })
        await #expect(throws: AttachmentCache.NoRemoteFetch.self) {
            _ = try await cache.remoteImageData(for: Self.url)
        }
    }
}
