import AppCore
import ChatKit
import Foundation
import Testing

/// Counts fetches, and can hold one until a test releases it, so a test can
/// act while a fetch is in flight.
private actor FetchRecorder {
    private(set) var calls: [String] = []
    private var failuresLeft = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func failNext(_ count: Int) {
        failuresLeft = count
    }

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

    func fetch(_ attachment: ChatKit.Attachment, _ size: AttachmentSize) async throws -> Data {
        calls.append("\(attachment.id)/\(size.rawValue)")
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw ChatError.server(status: 503, message: "try later")
        }
        return Data("\(attachment.id)/\(size.rawValue)".utf8)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AttachmentCacheTests {
    private static let image = ChatKit.Attachment(
        id: "token-1",
        name: "screen shot.png",
        contentType: "image/png"
    )

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "attachment-cache-tests-\(UUID().uuidString)")
    }

    private static func cache(_ recorder: FetchRecorder, directory: URL?, capacity: Int = 1_000_000)
        -> AttachmentCache {
        AttachmentCache(directory: directory, capacity: capacity) { attachment, size in
            try await recorder.fetch(attachment, size)
        }
    }

    /// Every file under `directory`, as paths relative to it.
    private static func files(in directory: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
            .map(\.lastPathComponent)
    }

    /// Bounded, so a condition that never comes true fails rather than hangs
    /// (`CLAUDE.md`: `.timeLimit` cannot stop a loop that never suspends on
    /// anything cancellable).
    private static func waitUntilHeld(_ recorder: FetchRecorder, count: Int) async throws {
        for _ in 0 ..< 1000 where await recorder.heldCount < count {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await recorder.heldCount == count)
    }

    // MARK: - Memory, then disk, then the backend

    @Test func theSecondRequestIsServedWithoutFetching() async throws {
        let recorder = FetchRecorder()
        let cache = Self.cache(recorder, directory: nil)
        let first = try await cache.data(for: Self.image, size: .preview)
        let second = try await cache.data(for: Self.image, size: .preview)
        #expect(first == second)
        #expect(await recorder.calls == ["token-1/preview"])
    }

    @Test func previewAndOriginalAreSeparateEntries() async throws {
        let recorder = FetchRecorder()
        let cache = Self.cache(recorder, directory: nil)
        _ = try await cache.data(for: Self.image, size: .preview)
        _ = try await cache.data(for: Self.image, size: .original)
        #expect(await recorder.calls == ["token-1/preview", "token-1/original"])
    }

    @Test func aRelaunchIsServedFromDisk() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = FetchRecorder()
        _ = try await Self.cache(before, directory: directory).data(for: Self.image, size: .preview)

        let after = FetchRecorder()
        let data = try await Self.cache(after, directory: directory).data(for: Self.image, size: .preview)
        #expect(data == Data("token-1/preview".utf8))
        #expect(await after.calls.isEmpty)
    }

    @Test func simultaneousRequestsShareOneFetch() async throws {
        let recorder = FetchRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: nil)
        async let first = cache.data(for: Self.image, size: .preview)
        try await Self.waitUntilHeld(recorder, count: 1)
        async let second = cache.data(for: Self.image, size: .preview)
        // The second caller must be waiting on the first fetch, not starting
        // one: give it time to start one if it were going to.
        try await Task.sleep(for: .milliseconds(20))
        await recorder.release()
        let (one, two) = try await (first, second)
        #expect(one == two)
        #expect(await recorder.calls == ["token-1/preview"])
    }

    @Test func aFailureIsNotCached() async throws {
        let recorder = FetchRecorder()
        await recorder.failNext(1)
        let cache = Self.cache(recorder, directory: nil)
        await #expect(throws: ChatError.self) {
            _ = try await cache.data(for: Self.image, size: .preview)
        }
        let retried = try await cache.data(for: Self.image, size: .preview)
        #expect(retried == Data("token-1/preview".utf8))
        #expect(await recorder.calls.count == 2)
    }

    // MARK: - The cap

    @Test func theOldestEntryIsRemovedWhenTheCapIsPassed() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Each entry is 15 bytes ("token-N/preview"), so two fit in 30 and a
        // third does not.
        let cache = Self.cache(FetchRecorder(), directory: directory, capacity: 30)
        for index in 1 ... 3 {
            let attachment = ChatKit.Attachment(
                id: "token-\(index)",
                name: "\(index).png",
                contentType: "image/png"
            )
            _ = try await cache.data(for: attachment, size: .preview)
            // Distinct modification times, so "oldest" is decided by order.
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(Set(Self.files(in: directory)) == ["2.png", "3.png"])
    }

    // MARK: - Erase

    @Test func eraseEmptiesMemoryAndDisk() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FetchRecorder()
        let cache = Self.cache(recorder, directory: directory)
        _ = try await cache.data(for: Self.image, size: .preview)
        // Positive control: something was on disk to erase.
        try #require(!Self.files(in: directory).isEmpty)

        await cache.erase()
        #expect(Self.files(in: directory).isEmpty)
        _ = try await cache.data(for: Self.image, size: .preview)
        #expect(await recorder.calls.count == 2)
    }

    /// The race sign-out cannot afford: a fetch already in flight when the
    /// account is erased must not write that account's image back afterwards.
    @Test func aFetchInFlightAtEraseNeverReachesDisk() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FetchRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: directory)
        let inFlight = Task { try await cache.data(for: Self.image, size: .preview) }
        try await Self.waitUntilHeld(recorder, count: 1)

        await cache.erase()
        await recorder.release()
        _ = try? await inFlight.value
        #expect(Self.files(in: directory).isEmpty)

        // And memory: the next request fetches again.
        _ = try await cache.data(for: Self.image, size: .preview)
        #expect(await recorder.calls.count == 2)
    }

    // MARK: - The file Quick Look opens

    @Test func theOriginalFileIsNamedForTheAttachment() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FetchRecorder()
        let cache = Self.cache(recorder, directory: directory)
        let url = try await cache.originalFile(for: Self.image)
        #expect(url.lastPathComponent == "screen shot.png")
        #expect(try Data(contentsOf: url) == Data("token-1/original".utf8))
        #expect(await recorder.calls == ["token-1/original"])
    }

    @Test(arguments: [
        ("a/b:c.png", "image/png", "a-b-c.png"),
        ("", "image/jpeg", "attachment.jpg"),
        ("diagram", "image/png", "diagram.png"),
        ("notes.pdf", "application/pdf", "notes.pdf"),
        ("..", "image/gif", "attachment.gif")
    ])
    func fileNamesAreMadeSafe(name: String, contentType: String, expected: String) {
        let attachment = ChatKit.Attachment(id: "t", name: name, contentType: contentType)
        #expect(AttachmentCache.fileName(for: attachment) == expected)
    }

    @Test func withNoDirectoryThereIsNoFileToOpen() async {
        let cache = Self.cache(FetchRecorder(), directory: nil)
        await #expect(throws: AttachmentCache.NoDirectory.self) {
            _ = try await cache.originalFile(for: Self.image)
        }
    }
}
