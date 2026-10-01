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

    /// A read is what keeps an entry: the cap removes the least recently
    /// *used*, not the oldest written. The name has a space, because
    /// `URL.path()` percent-encodes one and the touch failed silently for
    /// exactly the names macOS screenshots get (the review's Important 2).
    @Test func aReadRefreshesAnEntrySoTheCapRemovesAnother() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func attachment(_ index: Int) -> ChatKit.Attachment {
            ChatKit.Attachment(
                id: "token-\(index)",
                name: "Screen Shot \(index).png",
                contentType: "image/png"
            )
        }
        let writer = Self.cache(FetchRecorder(), directory: directory, capacity: 30)
        _ = try await writer.data(for: attachment(1), size: .preview)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await writer.data(for: attachment(2), size: .preview)
        try await Task.sleep(for: .milliseconds(20))
        // A fresh instance, so the read comes from disk rather than memory.
        let reader = Self.cache(FetchRecorder(), directory: directory, capacity: 30)
        _ = try await reader.data(for: attachment(1), size: .preview)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await reader.data(for: attachment(3), size: .preview)
        #expect(Set(Self.files(in: directory)) == ["Screen Shot 1.png", "Screen Shot 3.png"])
    }

    /// The one entry the trim never removes is the one it just wrote, or a
    /// single original larger than the cap would hand Quick Look a dead file.
    @Test func anEntryLargerThanTheWholeCapSurvivesItsOwnWrite() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Self.cache(FetchRecorder(), directory: directory, capacity: 4)
        let url = try await cache.originalFile(for: Self.image)
        #expect(try Data(contentsOf: url) == Data("token-1/original".utf8))
    }

    @Test func aDirectoryThatCannotBeWrittenIsAWriteFailureNotAMissingDirectory() async throws {
        let blocker = Self.directory()
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let cache = Self.cache(FetchRecorder(), directory: blocker)
        await #expect(throws: AttachmentCache.WriteFailed.self) {
            _ = try await cache.originalFile(for: Self.image)
        }
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
    }

    /// Terminal: the instance belonged to the account just signed out of,
    /// and a call that was already queued on it must not fetch and write
    /// that account's image into the directory the next session uses.
    @Test func anErasedCacheRefusesEveryLaterCall() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FetchRecorder()
        let cache = Self.cache(recorder, directory: directory)
        await cache.erase()
        await #expect(throws: AttachmentCache.Erased.self) {
            _ = try await cache.data(for: Self.image, size: .preview)
        }
        await #expect(throws: AttachmentCache.Erased.self) {
            _ = try await cache.originalFile(for: Self.image)
        }
        #expect(await recorder.calls.isEmpty)
        #expect(Self.files(in: directory).isEmpty)
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
    }

    /// `originalFile(for:)` writes after its own `await`, so it needs the
    /// same refusal `data(for:)` has (the review's Important 1).
    @Test func anOriginalInFlightAtEraseNeverReachesDisk() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FetchRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: directory)
        let inFlight = Task { try await cache.originalFile(for: Self.image) }
        try await Self.waitUntilHeld(recorder, count: 1)

        await cache.erase()
        await recorder.release()
        await #expect(throws: (any Error).self) { _ = try await inFlight.value }
        #expect(Self.files(in: directory).isEmpty)
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

    /// A file name's limit is 255 bytes, and 200 CJK characters are 600.
    @Test func aLongNameIsCutByBytesAndKeepsItsExtension() {
        let attachment = ChatKit.Attachment(
            id: "t", name: String(repeating: "日", count: 300) + ".png", contentType: "image/png"
        )
        let name = AttachmentCache.fileName(for: attachment)
        #expect(name.utf8.count <= 200)
        #expect(name.hasSuffix("日.png"))
    }

    @Test func withNoDirectoryThereIsNoFileToOpen() async {
        let cache = Self.cache(FetchRecorder(), directory: nil)
        await #expect(throws: AttachmentCache.NoDirectory.self) {
            _ = try await cache.originalFile(for: Self.image)
        }
    }
}
